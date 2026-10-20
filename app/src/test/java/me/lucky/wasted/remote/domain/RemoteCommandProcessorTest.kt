package me.lucky.wasted.remote.domain

import kotlinx.coroutines.runBlocking

import me.lucky.wasted.admin.ResetResult
import me.lucky.wasted.remote.data.RemoteCommandJournalEntity
import me.lucky.wasted.remote.data.RemoteCredentialStore
import me.lucky.wasted.remote.testing.FakeRemoteCommandDao
import me.lucky.wasted.testing.InMemorySharedPreferences

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteCommandProcessorTest {

    private class FakeApi : RemoteApi {
        val transitions = mutableListOf<TransitionCommandParams>()
        val failures = ArrayDeque<Throwable>()

        override suspend fun ensureAnonymousSession() = Unit

        override suspend fun claimEnrollment(params: ClaimEnrollmentParams): RemoteDeviceDto =
            error("not used")

        override suspend fun reconcile(params: ReconcileParams): RemoteReconcileResponse =
            error("not used")

        override suspend fun transitionCommand(params: TransitionCommandParams): RemoteCommandDto {
            failures.removeFirstOrNull()?.let { throw it }
            transitions.add(params)
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

    private var now = 5_000L
    private val dao = FakeRemoteCommandDao()
    private val api = FakeApi()
    private val credentials = RemoteCredentialStore(InMemorySharedPreferences()).apply {
        enrolled = true
        deviceId = "device-1"
    }
    private var debug = false
    private var supported = true
    private var restartResult = true
    private var restartCalls = 0
    private val resetCalls = mutableListOf<ResetResult>()

    private fun seed(commandId: String, type: String = "reset_timer", state: String = "queued") {
        dao.commands[commandId] = RemoteCommandJournalEntity(
            commandId = commandId,
            type = type,
            state = state,
            receivedAt = now,
            executingAt = null,
            terminalAt = null,
        )
    }

    private fun processor() = RemoteCommandProcessor(
        api = api,
        dao = dao,
        credentials = credentials,
        timer = object : RemoteTimerPort {
            override fun restartIfActive(): Boolean {
                restartCalls++
                return restartResult
            }
        },
        resetSupported = { supported },
        debugMode = { debug },
        reset = {
            ResetResult.Initiated("Device reset initiated").also { resetCalls.add(it) }
        },
        clock = { now },
    )

    private fun sent() = api.transitions.map {
        "${it.expectedState.name.lowercase()}->${it.newState.name.lowercase()}"
    }

    @Test
    fun `reset timer follows the documented order and reports restarted`() = runBlocking {
        seed("c1")

        val outcome = processor().processPending()

        assertEquals(1, outcome.processed)
        assertEquals(
            listOf("queued->received", "received->executing", "executing->applied"),
            sent(),
        )
        assertEquals("restarted", api.transitions.last().resultCode)
        assertEquals("applied", dao.commands.getValue("c1").state)
        assertEquals(1, restartCalls)
    }

    @Test
    fun `reset timer records inactive truthfully`() = runBlocking {
        restartResult = false
        seed("c1")

        processor().processPending()

        assertEquals("inactive", api.transitions.last().resultCode)
        assertEquals("applied", dao.commands.getValue("c1").state)
    }

    @Test
    fun `force reset is blocked by debug mode without touching the reset gate`() = runBlocking {
        debug = true
        seed("c1", type = "force_reset")

        processor().processPending()

        assertEquals(listOf("queued->received", "received->debug_blocked"), sent())
        assertEquals("debug_blocked", dao.commands.getValue("c1").state)
        assertTrue(resetCalls.isEmpty())
    }

    @Test
    fun `debug mode enabled before the boundary blocks the second check`() = runBlocking {
        var reads = 0
        val racingProcessor = RemoteCommandProcessor(
            api = api,
            dao = dao,
            credentials = credentials,
            timer = object : RemoteTimerPort {
                override fun restartIfActive() = true
            },
            resetSupported = { true },
            debugMode = { reads++ > 0 },
            reset = {
                ResetResult.Initiated("Device reset initiated").also { resetCalls.add(it) }
            },
            clock = { now },
        )
        seed("c1", type = "force_reset")

        racingProcessor.processPending()

        assertEquals(
            listOf("queued->received", "received->executing", "executing->debug_blocked"),
            sent(),
        )
        assertEquals("debug_blocked", dao.commands.getValue("c1").state)
        assertTrue(resetCalls.isEmpty())
    }

    @Test
    fun `force reset is rejected when reset is unsupported`() = runBlocking {
        supported = false
        seed("c1", type = "force_reset")

        processor().processPending()

        assertEquals(listOf("queued->received", "received->rejected"), sent())
        assertEquals("rejected", dao.commands.getValue("c1").state)
        assertTrue(resetCalls.isEmpty())
    }

    @Test
    fun `force reset executes exactly once after reset_initiated`() = runBlocking {
        seed("c1", type = "force_reset")

        processor().processPending()

        assertEquals(
            listOf("queued->received", "received->executing", "executing->reset_initiated"),
            sent(),
        )
        assertEquals("reset_initiated", dao.commands.getValue("c1").state)
        assertEquals(1, resetCalls.size)
    }

    @Test
    fun `interrupted force reset is failed and never executed`() = runBlocking {
        seed("c1", type = "force_reset", state = "executing")

        processor().processPending()

        assertEquals(listOf("executing->failed"), sent())
        assertEquals("interrupted_before_reset", api.transitions.single().resultCode)
        assertEquals("failed", dao.commands.getValue("c1").state)
        assertTrue(resetCalls.isEmpty())
    }

    @Test
    fun `interrupted reset timer finishes idempotently`() = runBlocking {
        seed("c1", type = "reset_timer", state = "executing")

        processor().processPending()

        assertEquals(listOf("executing->applied"), sent())
        assertEquals("applied", dao.commands.getValue("c1").state)
        assertEquals(1, restartCalls)
    }

    @Test
    fun `retryable send failures leave the command pending`() = runBlocking {
        api.failures.add(RemoteException(RemoteError.Network))
        seed("c1")

        val outcome = processor().processPending()

        assertEquals(1, outcome.failed)
        assertTrue(api.transitions.isEmpty())
        assertEquals("queued", dao.commands.getValue("c1").state)
    }

    @Test
    fun `fatal send conflicts mark the command failed`() = runBlocking {
        api.failures.add(RemoteException(RemoteError.Conflict))
        seed("c1")

        processor().processPending()

        assertEquals("failed", dao.commands.getValue("c1").state)
    }

    @Test
    fun `terminal commands are never re-executed`() = runBlocking {
        seed("c1", state = "applied")

        val outcome = processor().processPending()

        assertEquals(0, outcome.processed)
        assertEquals(0, outcome.failed)
        assertTrue(api.transitions.isEmpty())
    }

    @Test
    fun `unenrolled device processes nothing`() = runBlocking {
        credentials.enrolled = false
        credentials.deviceId = null
        seed("c1")

        val outcome = processor().processPending()

        assertEquals(0, outcome.processed)
        assertTrue(api.transitions.isEmpty())
    }
}
