package me.lucky.wasted.trigger.shared

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

import me.lucky.wasted.Preferences
import me.lucky.wasted.Trigger
import me.lucky.wasted.remote.data.RemoteConfigStore

class RestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val ctx = context ?: return
        val prefs = Preferences.new(ctx)
        val triggers = prefs.triggers
        val remoteConfigStore = RemoteConfigStore.new(ctx)
        val needsForeground = prefs.p2pEnabled ||
            (remoteConfigStore.remoteEnabled && remoteConfigStore.isConfigured) ||
            (prefs.isEnabled && (
                triggers.and(Trigger.LOCK.value) != 0 ||
                triggers.and(Trigger.USB.value) != 0))
        if (!needsForeground) return
        ContextCompat.startForegroundService(
            ctx.applicationContext,
            Intent(ctx.applicationContext, ForegroundService::class.java)
                .setAction(ForegroundService.ACTION_RECONFIGURE),
        )
    }
}
