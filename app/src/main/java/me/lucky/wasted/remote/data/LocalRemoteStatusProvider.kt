package me.lucky.wasted.remote.data

import android.content.Context
import android.os.Build

import me.lucky.wasted.Preferences
import me.lucky.wasted.Trigger
import me.lucky.wasted.admin.DeviceAdminManager
import me.lucky.wasted.remote.domain.LocalRemoteStatus
import me.lucky.wasted.remote.domain.RemoteStatusProvider
import me.lucky.wasted.trigger.lock.TimerCoordinator

/** Reads the real local device state reported to `device_reconcile`. */
class LocalRemoteStatusProvider(
    private val ctx: Context,
    private val prefs: Preferences = Preferences.new(ctx),
    private val credentials: RemoteCredentialStore = RemoteCredentialStore.new(ctx),
) : RemoteStatusProvider {

    override fun snapshot(): LocalRemoteStatus {
        val timer = TimerCoordinator.create(ctx).currentState()
        val admin = DeviceAdminManager(ctx)
        return LocalRemoteStatus(
            appliedSettingsRevision = credentials.appliedSettingsRevision,
            lockTimerMinutes = prefs.triggerLockCount,
            usbTriggerEnabled = prefs.triggers.and(Trigger.USB.value) != 0,
            timerRemainingSeconds = timer.remainingSeconds,
            timerRunning = timer.running,
            debugMode = prefs.isDebugMode,
            resetSupported = admin.getResetSupport().isSupported,
            remoteEnabled = credentials.enrolled,
            appVersion = appVersion(),
            androidSdk = Build.VERSION.SDK_INT,
        )
    }

    private fun appVersion(): String = runCatching {
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "unknown"
    }.getOrDefault("unknown")
}
