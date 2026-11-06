package me.lucky.wasted.trigger.shared

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

import me.lucky.wasted.Preferences
import me.lucky.wasted.remote.data.RemoteConfigStore
import me.lucky.wasted.remote.work.RemoteRecoveryWorker

class RestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_USER_UNLOCKED &&
            intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val ctx = context ?: return
        val prefs = Preferences.new(ctx)
        val remoteConfigStore = RemoteConfigStore.new(ctx)
        val remoteActive = remoteConfigStore.remoteEnabled && remoteConfigStore.isConfigured

        // Android 15+ blocks starting a foreground service directly from BOOT_COMPLETED.
        // WorkManager is the supported boot path; it also waits for a validated network.
        if (intent.action == Intent.ACTION_LOCKED_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_BOOT_COMPLETED
        ) {
            if (remoteActive) {
                RemoteRecoveryWorker.schedulePeriodic(ctx)
                RemoteRecoveryWorker.scheduleOnce(ctx)
            }
            // Never attempt a boot-time foreground-service start; USER_UNLOCKED or the worker
            // is the supported hand-off on Android 15+.
            return
        }

        val needsForeground = ForegroundRequirement.isRequired(
            enabled = prefs.isEnabled,
            triggers = prefs.triggers,
            p2pEnabled = prefs.p2pEnabled,
            remoteActive = remoteActive,
        )
        if (!needsForeground) return

        // USER_UNLOCKED and package replacement are not boot-start restrictions. The periodic
        // worker above remains the fallback if an OEM still refuses the foreground start.
        runCatching {
            ContextCompat.startForegroundService(
                ctx.applicationContext,
                Intent(ctx.applicationContext, ForegroundService::class.java)
                    .setAction(ForegroundService.ACTION_RECONFIGURE),
            )
        }
    }
}
