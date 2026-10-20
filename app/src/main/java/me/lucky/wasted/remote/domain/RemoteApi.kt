package me.lucky.wasted.remote.domain

/** Transport-agnostic remote API boundary; faked in JVM tests and implemented by the Supabase adapter. */
interface RemoteApi {
    suspend fun ensureAnonymousSession()
    suspend fun claimEnrollment(params: ClaimEnrollmentParams): RemoteDeviceDto
    suspend fun reconcile(params: ReconcileParams): RemoteReconcileResponse
    suspend fun transitionCommand(params: TransitionCommandParams): RemoteCommandDto
}

/** Local device state reported to `device_reconcile`. */
data class LocalRemoteStatus(
    val appliedSettingsRevision: Long,
    val lockTimerMinutes: Int,
    val usbTriggerEnabled: Boolean,
    val timerRemainingSeconds: Long,
    val timerRunning: Boolean,
    val debugMode: Boolean,
    val resetSupported: Boolean,
    val remoteEnabled: Boolean,
    val appVersion: String,
    val androidSdk: Int,
)

fun interface RemoteStatusProvider {
    fun snapshot(): LocalRemoteStatus
}
