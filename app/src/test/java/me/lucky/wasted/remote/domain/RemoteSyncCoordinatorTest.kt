package me.lucky.wasted.remote.domain

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking

import me.lucky.wasted.remote.data.RemoteCredentialStore
import me.lucky.wasted.remote.testing.FakeRemoteCommandDao
import me.lucky.wasted.testing.InMemorySharedPreferences

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteSyncCoordinatorTest {

    private class RecordingSettingsApplier : RemoteSettingsApplierPort {
        var lockTimerMinutes: Int? = null
        var usbTriggerEnabled: Boolean? = null
        var calls = 0

        override fun applyLockTimerMinutes(minutes: Int) {
            lockTimerMinutes = minutes
            calls++
        }

        override fun applyUsbTrigger(enabled: Boolean) {
            usbTriggerEnabled = enabled
            calls++
        }
    }

    private class FakeRemoteApi : RemoteApi {
        var ensureCalls = 0
        var reconcileCalls = 0
        var transitionCalls = 0
        val reconcileFailures = ArrayDeque<Throwable>()
        val transitionFailures = ArrayDeque<Throwable>()
        val reconcileStarted = CompletableDeferred<Unit>()
        var gate: CompletableDeferred<Unit>? = null
        var response: RemoteReconcileResponse? = null

        override suspend fun ensureAnonymousSession() {
            ensureCalls++
        }

        override suspend fun claimEnrollment(params: ClaimEnrollmentParams): RemoteDeviceDto =
            error("not used in these tests")

        override suspend fun reconcile(params: ReconcileParams): RemoteReconcileResponse {
            reconcileCalls++
            reconcileStarted.complete(Unit)
            gate?.await()
            reconcileFailures.removeFirstOrNull()?.let { throw it }
            return response ?: error("response not configured")
        }

        override suspend fun transitionCommand(params: TransitionCommandParams): RemoteCommandDto {
            transitionCalls++
            transitionFailures.removeFirstOrNull()?.let { throw it }
            return RemoteCommandDto(
                id = params.commandId,
                actionId = "action",
                commandType = RemoteCommandType.RESET_TIMER,
                state = params.newState,
                createdAt = "t",
                expiresAt = "t",
            )
        }
    }

    private var now = 1_000L
    private var available = true
    private val dao = FakeRemoteCommandDao()
    private val credentials = RemoteCredentialStore(InMemorySharedPreferences()).apply {
        enrolled = true
        deviceId = "device-1"
    }
    private val api = FakeRemoteApi()
    private val settings = RecordingSettingsApplier()
    private val sleeps = mutableListOf<Long>()
    private val emitted = mutableListOf<RemoteEvent>()

    private fun coordinator() = RemoteSyncCoordinator(
        api = api,
        dao = dao,
        credentials = credentials,
        statusProvider = {
            LocalRemoteStatus(
                appliedSettingsRevision = 0L,
                lockTimerMinutes = 1440,
                usbTriggerEnabled = true,
                timerRemainingSeconds = 0L,
                timerRunning = false,
                debugMode = true,
                resetSupported = true,
                remoteEnabled = true,
                appVersion = "2.0.0",
                androidSdk = 34,
            )
        },
        isRemoteAvailable = { available },
        settingsApplier = settings,
        events = RemoteEventSink { emitted.add(it) },
        clock = { now },
        sleep = { sleeps.add(it) },
    )

    private fun command(id: String) = RemoteCommandDto(
        id = id,
        actionId = "action-$id",
        commandType = RemoteCommandType.RESET_TIMER,
        state = RemoteCommandState.QUEUED,
        createdAt = "t",
        expiresAt = "t",
    )

    private fun response(
        commands: List<RemoteCommandDto>,
        revision: Long = 1L,
        lock: Int = 1440,
        usb: Boolean = true,
    ) = RemoteReconcileResponse(
        serverTime = "t",
        device = RemoteDeviceDto(
            id = "device-1",
            accountId = "account-1",
            installationId = "installation-1",
            name = "Phone",
            enrolledAt = "t",
        ),
        settings = RemoteSettingsDto(
            revision = revision,
            lockTimerMinutes = lock,
            usbTriggerEnabled = usb,
            initialized = true,
        ),
        commands = commands,
    )

    @Test
    fun `unconfigured install performs no work`() = runBlocking {
        available = false

        val outcome = coordinator().syncNow()

        assertEquals(SyncOutcome.NotConfigured, outcome)
        assertEquals(0, api.ensureCalls)
        assertEquals(0, api.reconcileCalls)
    }

    @Test
    fun `unenrolled install stops before networking`() = runBlocking {
        credentials.enrolled = false
        credentials.deviceId = null

        val outcome = coordinator().syncNow()

        assertEquals(SyncOutcome.NotEnrolled, outcome)
        assertEquals(0, api.reconcileCalls)
    }

    @Test
    fun `successful reconcile persists commands exactly once`() = runBlocking {
        api.response = response(listOf(command("c1"), command("c2")))

        val outcome = coordinator().syncNow()

        assertTrue(outcome is SyncOutcome.Success)
        assertEquals(2, (outcome as SyncOutcome.Success).commands)
        assertEquals(2, dao.commands.size)
        assertEquals(1440, settings.lockTimerMinutes)
        assertEquals(true, settings.usbTriggerEnabled)
        assertEquals(1L, credentials.appliedSettingsRevision)

        coordinator().syncNow()

        assertEquals(2, dao.commands.size)
        assertEquals(2, coordinator().pendingCommands().size)
    }

    @Test
    fun `account settings apply once per new revision`() = runBlocking {
        api.response = response(emptyList(), revision = 3L, lock = 720, usb = false)

        coordinator().syncNow()
        assertEquals(720, settings.lockTimerMinutes)
        assertEquals(false, settings.usbTriggerEnabled)
        assertEquals(3L, credentials.appliedSettingsRevision)
        assertEquals(listOf(RemoteEvent.Kind.SETTINGS_CHANGED), emitted.map { it.kind })
        assertEquals("settings-3", emitted.single().key)

        val callsAfterFirst = settings.calls
        coordinator().syncNow()
        assertEquals(callsAfterFirst, settings.calls)

        api.response = response(emptyList(), revision = 2L, lock = 60, usb = true)
        coordinator().syncNow()
        assertEquals(720, settings.lockTimerMinutes)
        assertEquals(3L, credentials.appliedSettingsRevision)
    }

    @Test
    fun `retryable failures back off and then succeed`() = runBlocking {
        api.response = response(emptyList())
        api.reconcileFailures.add(RemoteException(RemoteError.Network))
        api.reconcileFailures.add(RemoteException(RemoteError.RateLimited()))

        val outcome = coordinator().syncNow()

        assertTrue(outcome is SyncOutcome.Success)
        assertEquals(3, api.reconcileCalls)
        assertEquals(listOf(1_000L, 2_000L), sleeps)
    }

    @Test
    fun `fatal failures stop immediately with a sanitized reason`() = runBlocking {
        api.reconcileFailures.add(RemoteException(RemoteError.RlsDenied))

        val outcome = coordinator().syncNow()

        assertEquals(SyncOutcome.Failed("access denied"), outcome)
        assertEquals(1, api.reconcileCalls)
        assertTrue(sleeps.isEmpty())
    }

    @Test
    fun `duplicate signals coalesce into one follow-up run`() = runBlocking {
        api.response = response(emptyList())
        val gate = CompletableDeferred<Unit>()
        api.gate = gate
        val coordinator = coordinator()

        val first = async(Dispatchers.Default) { coordinator.syncNow() }
        api.reconcileStarted.await()

        assertEquals(SyncOutcome.Coalesced, coordinator.syncNow())

        gate.complete(Unit)
        assertTrue(first.await() is SyncOutcome.Success)
        assertEquals(2, api.reconcileCalls)
    }

    @Test
    fun `outbox retries transitions and drops fatal failures`() = runBlocking {
        val coordinator = coordinator()

        api.transitionFailures.add(RemoteException(RemoteError.Network))
        coordinator.queueTransition(
            TransitionCommandParams("device-1", "c1", RemoteCommandState.QUEUED, RemoteCommandState.RECEIVED),
        )
        assertEquals(0, coordinator.drainOutbox())
        assertEquals(1, dao.outbox.size)

        now += 1_000
        assertEquals(1, coordinator.drainOutbox())
        assertTrue(dao.outbox.isEmpty())
        assertEquals(2, api.transitionCalls)

        api.transitionFailures.add(RemoteException(RemoteError.RlsDenied))
        coordinator.queueTransition(
            TransitionCommandParams("device-1", "c2", RemoteCommandState.QUEUED, RemoteCommandState.RECEIVED),
        )
        assertEquals(0, coordinator.drainOutbox())
        assertTrue(dao.outbox.isEmpty())
    }
}
