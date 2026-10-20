package me.lucky.wasted.remote.domain

import java.util.UUID

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.Json

import me.lucky.wasted.remote.data.RemoteCommandDao
import me.lucky.wasted.remote.data.RemoteCommandJournalEntity
import me.lucky.wasted.remote.data.RemoteCredentialStore
import me.lucky.wasted.remote.data.RemoteOutboxEntity

sealed class SyncOutcome {
    data object NotConfigured : SyncOutcome()
    data object NotEnrolled : SyncOutcome()
    data object Coalesced : SyncOutcome()
    data class Success(val commands: Int) : SyncOutcome()
    data class Failed(val reason: String) : SyncOutcome()
}

/**
 * Single-flight reconciliation. Duplicate signals coalesce into at most one follow-up run.
 * Returned commands are committed to the encrypted journal before any execution (execution is
 * orchestrated separately); server transitions retry through the encrypted outbox.
 */
class RemoteSyncCoordinator(
    private val api: RemoteApi,
    private val dao: RemoteCommandDao,
    private val credentials: RemoteCredentialStore,
    private val statusProvider: RemoteStatusProvider,
    private val isRemoteAvailable: () -> Boolean,
    private val retryPolicy: RemoteRetryPolicy = RemoteRetryPolicy(),
    private val clock: () -> Long = System::currentTimeMillis,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    companion object {
        private const val KIND_TRANSITION = "transition"
        private val json = Json { encodeDefaults = true }
    }

    private val mutex = Mutex()

    @Volatile
    private var pendingSignal = false

    suspend fun syncNow(): SyncOutcome {
        if (!isRemoteAvailable()) return SyncOutcome.NotConfigured
        val deviceId = credentials.deviceId
        if (!credentials.enrolled || deviceId == null) return SyncOutcome.NotEnrolled

        if (!mutex.tryLock()) {
            pendingSignal = true
            return SyncOutcome.Coalesced
        }
        try {
            var outcome: SyncOutcome = SyncOutcome.Success(0)
            do {
                pendingSignal = false
                outcome = runReconcile(deviceId)
            } while (pendingSignal && outcome is SyncOutcome.Success)
            return outcome
        } finally {
            mutex.unlock()
        }
    }

    suspend fun pendingCommands(): List<RemoteCommandJournalEntity> =
        dao.commandsInStates(listOf("queued", "received", "executing"))

    /** Queue a server transition for retry after a retryable failure. */
    suspend fun queueTransition(params: TransitionCommandParams) {
        dao.insertOutbox(
            RemoteOutboxEntity(
                id = UUID.randomUUID().toString(),
                kind = KIND_TRANSITION,
                commandId = params.commandId,
                payload = json.encodeToString(TransitionCommandParams.serializer(), params),
                createdAt = clock(),
                attemptCount = 0,
                nextAttemptAt = clock(),
            ),
        )
    }

    /** Retries due outbox entries; fatal failures are dropped instead of looping forever. */
    suspend fun drainOutbox(limit: Int = 10): Int {
        val due = dao.dueOutbox(clock(), limit)
        var sent = 0
        for (entry in due) {
            if (entry.kind != KIND_TRANSITION) {
                dao.deleteOutbox(entry.id)
                continue
            }
            val params = runCatching {
                json.decodeFromString(TransitionCommandParams.serializer(), entry.payload)
            }.getOrNull()
            if (params == null) {
                dao.deleteOutbox(entry.id)
                continue
            }
            try {
                api.transitionCommand(params)
                dao.deleteOutbox(entry.id)
                sent++
            } catch (e: RemoteException) {
                val retry = retryPolicy.shouldRetry(e.error) &&
                    entry.attemptCount + 1 < retryPolicy.maxAttempts
                if (retry) {
                    dao.updateOutboxAttempt(
                        entry.id,
                        entry.attemptCount + 1,
                        clock() + retryPolicy.delayMillis(entry.attemptCount, e.error),
                    )
                } else {
                    dao.deleteOutbox(entry.id)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // keep the entry for a later attempt
            }
        }
        return sent
    }

    private suspend fun runReconcile(deviceId: String): SyncOutcome {
        drainOutbox()

        val status = statusProvider.snapshot()
        val params = ReconcileParams(
            deviceId = deviceId,
            appliedSettingsRevision = status.appliedSettingsRevision,
            actualLockTimerMinutes = status.lockTimerMinutes,
            actualUsbTriggerEnabled = status.usbTriggerEnabled,
            timerRemainingSeconds = status.timerRemainingSeconds,
            timerRunning = status.timerRunning,
            debugMode = status.debugMode,
            resetSupported = status.resetSupported,
            remoteEnabled = status.remoteEnabled,
            appVersion = status.appVersion,
            androidSdk = status.androidSdk,
        )

        var attempt = 0
        while (true) {
            try {
                api.ensureAnonymousSession()
                val response = api.reconcile(params)
                response.commands.forEach { command ->
                    dao.insertCommand(
                        RemoteCommandJournalEntity(
                            commandId = command.id,
                            type = command.commandType.name.lowercase(),
                            state = command.state.name.lowercase(),
                            receivedAt = clock(),
                            executingAt = null,
                            terminalAt = null,
                        ),
                    )
                }
                return SyncOutcome.Success(response.commands.size)
            } catch (e: RemoteException) {
                if (!retryPolicy.shouldRetry(e.error) || attempt + 1 >= retryPolicy.maxAttempts) {
                    return SyncOutcome.Failed(e.error.sanitizedReason)
                }
                sleep(retryPolicy.delayMillis(attempt, e.error))
                attempt++
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                return SyncOutcome.Failed("unexpected error")
            }
        }
    }
}
