package me.lucky.wasted.remote

import android.content.Context

import me.lucky.wasted.Preferences
import me.lucky.wasted.Trigger
import me.lucky.wasted.admin.DeviceAdminManager
import me.lucky.wasted.admin.ResetExecutor
import me.lucky.wasted.remote.data.LocalRemoteStatusProvider
import me.lucky.wasted.remote.data.RemoteConfigStore
import me.lucky.wasted.remote.data.RemoteCredentialStore
import me.lucky.wasted.remote.data.RemoteDatabase
import me.lucky.wasted.remote.data.SupabaseRemoteRepository
import me.lucky.wasted.remote.domain.RemoteCommandProcessor
import me.lucky.wasted.remote.domain.RemoteSettingsApplierPort
import me.lucky.wasted.remote.domain.RemoteSyncCoordinator
import me.lucky.wasted.remote.domain.RemoteTimerPort
import me.lucky.wasted.remote.domain.SyncOutcome
import me.lucky.wasted.settings.LocalSettingsApplier
import me.lucky.wasted.trigger.lock.TimerCoordinator

/**
 * Single composition root for the remote stack, shared by the foreground service and the
 * WorkManager recovery path. [create] returns null when the fail-closed configuration boundary
 * is closed, guaranteeing zero network work for unconfigured installs.
 */
class RemoteEngine private constructor(
    val repository: SupabaseRemoteRepository,
    val credentials: RemoteCredentialStore,
    private val coordinator: RemoteSyncCoordinator,
    private val processor: RemoteCommandProcessor,
) {
    companion object {
        fun create(ctx: Context): RemoteEngine? {
            val configStore = RemoteConfigStore.new(ctx)
            if (!configStore.canStartRemoteWork()) return null

            val credentials = RemoteCredentialStore.new(ctx)
            val repository = SupabaseRemoteRepository(configStore, credentials)
            val dao = RemoteDatabase.getInstance(ctx).remoteCommandDao()
            val applier = LocalSettingsApplier.create(ctx)

            val coordinator = RemoteSyncCoordinator(
                api = repository,
                dao = dao,
                credentials = credentials,
                statusProvider = LocalRemoteStatusProvider(ctx),
                settingsApplier = object : RemoteSettingsApplierPort {
                    override fun applyLockTimerMinutes(minutes: Int) =
                        applier.setLockTimerMinutes(minutes)

                    override fun applyUsbTrigger(enabled: Boolean) =
                        applier.setTrigger(Trigger.USB, enabled)
                },
                isRemoteAvailable = { repository.isAvailable },
            )

            val processor = RemoteCommandProcessor(
                api = repository,
                dao = dao,
                credentials = credentials,
                timer = object : RemoteTimerPort {
                    override fun restartIfActive(): Boolean =
                        TimerCoordinator.create(ctx).restartIfActive()
                },
                resetSupported = {
                    DeviceAdminManager(ctx).getResetSupport().isSupported
                },
                debugMode = { Preferences.new(ctx).isDebugMode },
                reset = { ResetExecutor.create(ctx).execute() },
            )

            return RemoteEngine(repository, credentials, coordinator, processor)
        }
    }

    suspend fun runSync(): SyncOutcome {
        val outcome = coordinator.syncNow()
        processor.processPending()
        return outcome
    }

    fun close() {
        repository.close()
    }
}
