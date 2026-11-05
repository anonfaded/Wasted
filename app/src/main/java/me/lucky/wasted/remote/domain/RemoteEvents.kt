package me.lucky.wasted.remote.domain

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** A user-facing remote event; notification delivery and gating happen in the Android layer. */
data class RemoteEvent(
    val kind: Kind,
    val key: String,
    val title: String,
    val message: String,
) {
    enum class Kind {
        SETTINGS_CHANGED,
        SYNC_SUCCEEDED,
        RESET_TIMER_APPLIED,
        FORCE_RESET_INITIATED,
        DEBUG_BLOCKED,
        DEBUG_MODE_CHANGED,
        COMMAND_FAILED,
    }
}

fun interface RemoteEventSink {
    fun emit(event: RemoteEvent)
}

/** In-process events for an open Remote Management screen; no persistence or network. */
object RemoteEventBus {
    private val mutableEvents = MutableSharedFlow<RemoteEvent>(
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val events = mutableEvents.asSharedFlow()

    fun publish(event: RemoteEvent) {
        mutableEvents.tryEmit(event)
    }
}
