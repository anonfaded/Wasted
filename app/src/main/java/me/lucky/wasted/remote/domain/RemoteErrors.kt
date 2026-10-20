package me.lucky.wasted.remote.domain

/** Sanitized remote failure classes; raw server text never leaves this layer. */
sealed class RemoteError(val sanitizedReason: String) {
    data object Network : RemoteError("network unavailable")
    data class RateLimited(val retryAfterMillis: Long? = null) : RemoteError("rate limited")
    data class Server(val statusCode: Int) : RemoteError("server error")
    data object Authentication : RemoteError("authentication failed")
    data object RlsDenied : RemoteError("access denied")
    data object Conflict : RemoteError("state conflict")
    data object Validation : RemoteError("request rejected")
    data class Unknown(val detail: String?) : RemoteError("unexpected error")
}

class RemoteException(val error: RemoteError, cause: Throwable? = null) :
    Exception(error.sanitizedReason, cause)

object RemoteErrors {

    /**
     * Retryable: network, rate limiting, 5xx.
     * Fatal: authentication, RLS denials, validation, conflicts, expiry, illegal transitions.
     */
    fun classify(
        statusCode: Int?,
        sqlState: String?,
        isNetwork: Boolean,
        message: String?,
    ): RemoteError {
        if (isNetwork) return RemoteError.Network
        if (statusCode == 429) return RemoteError.RateLimited()
        if (statusCode != null && statusCode >= 500) return RemoteError.Server(statusCode)
        if (statusCode == 401) return RemoteError.Authentication
        if (statusCode == 403 || sqlState == "42501") return RemoteError.RlsDenied

        val text = message.orEmpty()
        return when {
            sqlState == "P0001" || sqlState == null -> when {
                text.contains("revision conflict", ignoreCase = true) -> RemoteError.Conflict
                text.contains("state conflict", ignoreCase = true) -> RemoteError.Conflict
                text.contains("illegal transition", ignoreCase = true) -> RemoteError.Conflict
                text.contains("expired", ignoreCase = true) -> RemoteError.Conflict
                text.contains("not supported", ignoreCase = true) -> RemoteError.Validation
                text.contains("not found", ignoreCase = true) -> RemoteError.Validation
                text.contains("authentication required", ignoreCase = true) -> RemoteError.Authentication
                text.isBlank() -> RemoteError.Unknown(null)
                else -> RemoteError.Validation
            }
            else -> RemoteError.Unknown(text.take(120))
        }
    }
}
