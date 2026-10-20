package me.lucky.wasted.remote.data

import android.util.Log

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.query.filter.FilterOperator
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import io.github.jan.supabase.realtime.realtime

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Channel lifecycle only: subscribes to the device's commands and the account's settings.
 * Every change — and every (re)subscribe — is only a "sync required" invalidation signal;
 * the authoritative state always comes from device_reconcile.
 */
class RemoteRealtimeClient(
    private val clientProvider: () -> SupabaseClient?,
) {
    companion object {
        private const val TAG = "RemoteRealtime"
        private const val CHANNEL_TOPIC = "wasted:remote-sync"
    }

    private var channel: RealtimeChannel? = null
    private val collectJobs = mutableListOf<Job>()

    suspend fun start(
        scope: CoroutineScope,
        deviceId: String,
        accountId: String?,
        onSyncRequired: () -> Unit,
    ) {
        stop()
        val client = clientProvider() ?: return

        val newChannel = client.channel(CHANNEL_TOPIC)

        val commandsFlow = newChannel.postgresChangeFlow<PostgresAction>(schema = "public") {
            table = "device_commands"
            filter("device_id", FilterOperator.EQ, deviceId)
        }
        collectJobs += scope.launch {
            commandsFlow.collect { onSyncRequired() }
        }

        if (accountId != null) {
            val settingsFlow = newChannel.postgresChangeFlow<PostgresAction>(schema = "public") {
                table = "account_settings"
                filter("account_id", FilterOperator.EQ, accountId)
            }
            collectJobs += scope.launch {
                settingsFlow.collect { onSyncRequired() }
            }
        }

        collectJobs += scope.launch {
            newChannel.status.collect { status ->
                if (status == RealtimeChannel.Status.SUBSCRIBED) onSyncRequired()
            }
        }

        newChannel.subscribe()
        channel = newChannel
        Log.i(TAG, "Realtime channel joined")
    }

    suspend fun stop() {
        collectJobs.forEach { it.cancel() }
        collectJobs.clear()
        val current = channel ?: return
        channel = null
        val client = clientProvider() ?: return
        runCatching { client.realtime.removeChannel(current) }
        Log.i(TAG, "Realtime channel removed")
    }
}
