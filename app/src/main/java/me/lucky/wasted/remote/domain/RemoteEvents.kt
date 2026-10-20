package me.lucky.wasted.remote.domain

/** A user-facing remote event; notification delivery and gating happen in the Android layer. */
data class RemoteEvent(
    val kind: Kind,
    val key: String,
    val title: String,
    val message: String,
) {
    enum class Kind {
        SETTINGS_CHANGED,
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
