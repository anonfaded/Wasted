package me.lucky.wasted.trigger.shared

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

import me.lucky.wasted.Preferences
import me.lucky.wasted.remote.data.RemoteConfigStore

class RestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val ctx = context ?: return
        val prefs = Preferences.new(ctx)
        val remoteConfigStore = RemoteConfigStore.new(ctx)
        val remoteActive = remoteConfigStore.remoteEnabled && remoteConfigStore.isConfigured
        val needsForeground = ForegroundRequirement.isRequired(
            enabled = prefs.isEnabled,
            triggers = prefs.triggers,
            p2pEnabled = prefs.p2pEnabled,
            remoteActive = remoteActive,
        )
        if (!needsForeground) return
        ContextCompat.startForegroundService(
            ctx.applicationContext,
            Intent(ctx.applicationContext, ForegroundService::class.java)
                .setAction(ForegroundService.ACTION_RECONFIGURE),
        )
    }
}
