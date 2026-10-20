package me.lucky.wasted.trigger.shared

import android.app.KeyguardManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.IBinder
import android.os.UserManager
import android.util.Log
import androidx.core.app.NotificationCompat

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

import me.lucky.wasted.Preferences
import me.lucky.wasted.R
import me.lucky.wasted.Trigger
import me.lucky.wasted.Utils
import me.lucky.wasted.p2p.P2PController
import me.lucky.wasted.remote.RemoteEngine
import me.lucky.wasted.remote.data.RemoteConfigStore
import me.lucky.wasted.remote.data.RemoteRealtimeClient
import me.lucky.wasted.remote.domain.SyncOutcome
import me.lucky.wasted.remote.work.RemoteRecoveryWorker
import me.lucky.wasted.trigger.lock.TimerCoordinator

class ForegroundService : Service() {
    companion object {
        const val ACTION_RECONFIGURE = "me.lucky.wasted.action.RECONFIGURE"
        private const val TAG = "ForegroundService"
        private const val NOTIFICATION_ID = 1000
        private const val NOTIFICATION_ID_REMOTE_SYNC = 1001
        private const val ACTION_USB_STATE = "android.hardware.usb.action.USB_STATE"
        private const val REMOTE_HEARTBEAT_MS = 60_000L
    }

    private lateinit var prefs: Preferences
    private val remoteConfigStore by lazy { RemoteConfigStore.new(this) }

    private var lockReceiver: LockReceiver? = null
    private var usbReceiver: UsbReceiver? = null
    private var p2pStarted = false

    private var remoteStarted = false
    private var remoteScope: CoroutineScope? = null
    private var remoteRealtime: RemoteRealtimeClient? = null
    private var remoteEngine: RemoteEngine? = null
    private var remoteNetworkCallback: ConnectivityManager.NetworkCallback? = null

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
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? { return null }

    /**
     * Idempotent. startForeground runs before any subsystem side effect;
     * each subsystem is then diffed independently of the others.
     */
    private fun reconfigure() {
        val desired = SubsystemDesired.from(
            triggers = prefs.triggers,
            p2pEnabled = prefs.p2pEnabled,
            remoteActive = remoteConfigStore.remoteEnabled && remoteConfigStore.isConfigured,
        )
        startForegroundWithTypes(desired)
        syncLockReceiver(desired.lockReceiver)
        syncUsbReceiver(desired.usbReceiver)
        syncP2p(desired.p2p)
        syncRemote(desired.remote)
        if (!desired.hasActiveSubsystem()) stopSelf()
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
        val unlocked = getSystemService(UserManager::class.java).isUserUnlocked
        val active = wanted && unlocked
        if (active == remoteStarted) return
        if (active) startRemote() else stopRemote()
    }

    private fun startRemote() {
        try {
            val engine = RemoteEngine.create(this) ?: return
            val realtime = RemoteRealtimeClient { engine.repository.clientForRealtime() }
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

            remoteStarted = true
            remoteScope = scope
            remoteRealtime = realtime
            remoteEngine = engine

            val runSync: suspend () -> Unit = {
                val outcome = runCatching { engine.runSync() }.getOrNull()
                if (outcome is SyncOutcome.Failed) {
                    if (outcome.retryable) {
                        RemoteRecoveryWorker.scheduleOnce(this)
                    }
                    if (engine.credentials.notificationsEnabled) {
                        NotificationManager(this).notifyRemoteEvent(
                            NOTIFICATION_ID_REMOTE_SYNC,
                            "Remote sync failed",
                            outcome.reason,
                        )
                    }
                }
            }

            scope.launch {
                runCatching {
                    val deviceId = engine.credentials.deviceId
                    if (engine.credentials.enrolled && deviceId != null) {
                        realtime.start(scope, deviceId, engine.credentials.accountId) {
                            scope.launch { runSync() }
                        }
                    }
                }.onFailure { Log.w(TAG, "Realtime start failed: ${it.message}") }
            }

            // Heartbeat: reconcile every 60s while enabled, enrolled, unlocked, and connected.
            scope.launch {
                while (isActive) {
                    val unlocked = getSystemService(UserManager::class.java).isUserUnlocked
                    if (unlocked && hasNetwork()) {
                        runSync()
                    }
                    delay(REMOTE_HEARTBEAT_MS)
                }
            }

            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    scope.launch { runSync() }
                }
            }
            runCatching {
                getSystemService(ConnectivityManager::class.java)
                    .registerDefaultNetworkCallback(callback)
            }.onFailure { Log.w(TAG, "Network callback registration failed: ${it.message}") }
            remoteNetworkCallback = callback

            RemoteRecoveryWorker.schedulePeriodic(this)

            Log.i(TAG, "Remote subsystem started")
        } catch (e: Exception) {
            Log.e(TAG, "Remote subsystem failed to start: ${e.message}")
            remoteStarted = false
            remoteScope?.cancel()
            remoteScope = null
            remoteRealtime = null
            remoteEngine = null
        }
    }

    private fun stopRemote() {
        if (!remoteStarted) return
        remoteStarted = false

        remoteNetworkCallback?.let { callback ->
            runCatching {
                getSystemService(ConnectivityManager::class.java)
                    .unregisterNetworkCallback(callback)
            }
        }
        remoteNetworkCallback = null

        RemoteRecoveryWorker.cancelPeriodic(this)

        val scope = remoteScope
        val realtime = remoteRealtime
        val engine = remoteEngine
        remoteScope = null
        remoteRealtime = null
        remoteEngine = null
        if (scope == null) return

        // Unsubscribe Realtime and remove its channel, then cancel the remote scope.
        scope.launch {
            runCatching { realtime?.stop() }
            engine?.close()
            scope.cancel()
        }
        Log.i(TAG, "Remote subsystem stopped")
    }

    private fun hasNetwork(): Boolean = runCatching {
        getSystemService(ConnectivityManager::class.java).activeNetwork != null
    }.getOrDefault(false)

    private fun unregisterSubsystemReceivers() {
        lockReceiver?.let { runCatching { unregisterReceiver(it) } }
        lockReceiver = null
        usbReceiver?.let { runCatching { unregisterReceiver(it) } }
        usbReceiver = null
    }

    private fun startForegroundWithTypes(desired: SubsystemDesired) {
        val notification = NotificationCompat.Builder(this, NotificationManager.CHANNEL_DEFAULT_ID)
                .setContentTitle(getString(R.string.foreground_service_notification_title))
                .setSmallIcon(android.R.drawable.ic_delete)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()

        val mask = ForegroundTypes.runtimeMask(Build.VERSION.SDK_INT, desired.p2p, desired.remote)
        if (mask != 0) {
            startForeground(NOTIFICATION_ID, notification, mask)
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
