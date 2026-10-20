package me.lucky.wasted.remote.domain

/** Narrow ports used by the remote execution engine; faked in JVM tests. */
interface RemoteSettingsApplierPort {
    fun applyLockTimerMinutes(minutes: Int)
    fun applyUsbTrigger(enabled: Boolean)
}

interface RemoteTimerPort {
    fun restartIfActive(): Boolean
}
