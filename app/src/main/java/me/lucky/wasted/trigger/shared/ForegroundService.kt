package me.lucky.wasted.trigger.shared

import android.app.KeyguardManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

import me.lucky.wasted.Preferences
import me.lucky.wasted.R
import me.lucky.wasted.Trigger
import me.lucky.wasted.Utils
import me.lucky.wasted.p2p.P2PController
import me.lucky.wasted.remote.data.RemoteConfigStore
import me.lucky.wasted.trigger.lock.TimerCoordinator

class ForegroundService : Service() {
    companion object {
        const val ACTION_RECONFIGURE = "me.lucky.wasted.action.RECONFIGURE"
        private const val NOTIFICATION_ID = 1000
        private const val ACTION_USB_STATE = "android.hardware.usb.action.USB_STATE"
    }

    private lateinit var prefs: Preferences
    private val remoteConfigStore by lazy { RemoteConfigStore.new(this) }

    private var lockReceiver: LockReceiver? = null
    private var usbReceiver: UsbReceiver? = null
    private var p2pStarted = false
    private var remoteStarted = false

    override fun onCreate() {
        super.onCreate()
        prefs = Preferences.new(this)
    }

    override fun onDestroy() {
        super.onDestroy()
        unregisterSubsystemReceivers()
        stopP2p()
        stopRemote()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        reconfigure()
        startForegroundWithTypes()
        if (!hasActiveSubsystem()) stopSelf()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? { return null }

    /** Idempotent: diffs desired vs actual state per subsystem — one subsystem never affects another. */
    private fun reconfigure() {
        val triggers = prefs.triggers
        syncLockReceiver(triggers.and(Trigger.LOCK.value) != 0)
        syncUsbReceiver(triggers.and(Trigger.USB.value) != 0)
        syncP2p(prefs.p2pEnabled)
        syncRemote(remoteConfigStore.remoteEnabled && remoteConfigStore.isConfigured)
    }

    private fun syncLockReceiver(wanted: Boolean) {
        if (wanted == (lockReceiver != null)) return
        if (wanted) {
            val receiver = LockReceiver(getSystemService(KeyguardManager::class.java).isDeviceLocked)
            registerReceiver(receiver, IntentFilter().apply {
                addAction(Intent.ACTION_USER_PRESENT)
                addAction(Intent.ACTION_SCREEN_OFF)
            })
            lockReceiver = receiver
        } else {
            lockReceiver?.let { runCatching { unregisterReceiver(it) } }
            lockReceiver = null
        }
    }

    private fun syncUsbReceiver(wanted: Boolean) {
        if (wanted == (usbReceiver != null)) return
        if (wanted) {
            val receiver = UsbReceiver()
            registerReceiver(receiver, IntentFilter(ACTION_USB_STATE))
            usbReceiver = receiver
        } else {
            usbReceiver?.let { runCatching { unregisterReceiver(it) } }
            usbReceiver = null
        }
    }

    private fun syncP2p(wanted: Boolean) {
        if (wanted == p2pStarted) return
        if (wanted) {
            P2PController.getInstance(this).start()
            p2pStarted = true
        } else {
            stopP2p()
        }
    }

    private fun stopP2p() {
        if (!p2pStarted) return
        P2PController.instanceOrNull()?.stop()
        p2pStarted = false
    }

    private fun syncRemote(wanted: Boolean) {
        // Phase 2 wires RemoteSyncCoordinator here; state tracking keeps the service alive meanwhile.
        remoteStarted = wanted
    }

    private fun stopRemote() {
        remoteStarted = false
    }

    private fun hasActiveSubsystem() =
        lockReceiver != null || usbReceiver != null || p2pStarted || remoteStarted

    private fun unregisterSubsystemReceivers() {
        lockReceiver?.let { runCatching { unregisterReceiver(it) } }
        lockReceiver = null
        usbReceiver?.let { runCatching { unregisterReceiver(it) } }
        usbReceiver = null
    }

    private fun startForegroundWithTypes() {
        val notification = NotificationCompat.Builder(this, NotificationManager.CHANNEL_DEFAULT_ID)
                .setContentTitle(getString(R.string.foreground_service_notification_title))
                .setSmallIcon(android.R.drawable.ic_delete)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            var mask = 0
            if (p2pStarted) mask = mask or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            if (remoteStarted) mask = mask or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            if (mask != 0) {
                startForeground(NOTIFICATION_ID, notification, mask)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (p2pStarted) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private class LockReceiver(private var locked: Boolean) : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (Preferences.new(context ?: return).triggers.and(Trigger.LOCK.value) == 0)
                return
            when (intent?.action) {
                Intent.ACTION_USER_PRESENT -> {
                    locked = false
                    TimerCoordinator.create(context).cancel()
                }
                Intent.ACTION_SCREEN_OFF -> {
                    if (locked) return
                    locked = true
                    Thread(Runner(context, goAsync())).start()
                }
            }
        }

        private class Runner(
            private val ctx: Context,
            private val pendingResult: PendingResult,
        ) : Runnable {
            override fun run() {
                val timer = TimerCoordinator.create(ctx)
                var delay = 1000L
                while (!timer.schedule()) {
                    Thread.sleep(delay)
                    delay = delay.shl(1)
                }
                pendingResult.finish()
            }
        }
    }

    private class UsbReceiver : BroadcastReceiver() {
        companion object {
            private const val KEY_1 = "connected"
            private const val KEY_2 = "host_connected"
        }

        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_USB_STATE) return
            val utils = Utils(context ?: return)
            if (!utils.isDeviceLocked()) return
            val extras = intent.extras ?: return
            if (!extras.getBoolean(KEY_1) && !extras.getBoolean(KEY_2)) return
            utils.fire(Trigger.USB)
        }
    }
}
