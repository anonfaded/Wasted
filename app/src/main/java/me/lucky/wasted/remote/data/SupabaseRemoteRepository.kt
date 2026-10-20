package me.lucky.wasted.remote.data

import java.io.IOException

import android.util.Log

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.exception.PostgrestRestException
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.realtime.Realtime

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

import me.lucky.wasted.remote.domain.ClaimEnrollmentParams
import me.lucky.wasted.remote.domain.ReconcileParams
import me.lucky.wasted.remote.domain.RemoteApi
import me.lucky.wasted.remote.domain.RemoteCommandDto
import me.lucky.wasted.remote.domain.RemoteDeviceDto
import me.lucky.wasted.remote.domain.RemoteError
import me.lucky.wasted.remote.domain.RemoteErrors
import me.lucky.wasted.remote.domain.RemoteException
import me.lucky.wasted.remote.domain.RemoteReconcileResponse
import me.lucky.wasted.remote.domain.TransitionCommandParams

/**
 * The only place that touches the Supabase client. The client is created lazily and only when
 * the fail-closed configuration boundary is open; a fresh or unconfigured install performs
 * zero network work. SDK failures are converted to sanitized [RemoteException]s at this boundary.
 */
class SupabaseRemoteRepository(
    private val configStore: RemoteConfigStore,
    private val credentialStore: RemoteCredentialStore,
) : RemoteApi {
    companion object {
        private const val TAG = "SupabaseRemote"
        private val json = Json { encodeDefaults = true }
    }

    @Volatile
    private var client: SupabaseClient? = null

    val isAvailable: Boolean
        get() = configStore.canStartRemoteWork()

    override suspend fun ensureAnonymousSession() = guarded {
        val supabase = requireClient()
        if (supabase.auth.currentSessionOrNull() == null) {
            supabase.auth.signInAnonymously()
            Log.i(TAG, "Anonymous device session established")
        }
    }

    override suspend fun claimEnrollment(params: ClaimEnrollmentParams): RemoteDeviceDto = guarded {
        Log.d(TAG, "claim_device_enrollment")
        val body = json.encodeToJsonElement(ClaimEnrollmentParams.serializer(), params).jsonObject
        requireClient().postgrest.rpc("claim_device_enrollment", body)
            .decodeAs<RemoteDeviceDto>()
    }

    override suspend fun reconcile(params: ReconcileParams): RemoteReconcileResponse = guarded {
        val body = json.encodeToJsonElement(ReconcileParams.serializer(), params).jsonObject
        requireClient().postgrest.rpc("device_reconcile", body)
            .decodeAs<RemoteReconcileResponse>()
    }

    override suspend fun transitionCommand(params: TransitionCommandParams): RemoteCommandDto = guarded {
        Log.d(
            TAG,
            "device_transition_command ${params.commandId} ${params.expectedState} -> ${params.newState}",
        )
        val body = json.encodeToJsonElement(TransitionCommandParams.serializer(), params).jsonObject
        requireClient().postgrest.rpc("device_transition_command", body)
            .decodeAs<RemoteCommandDto>()
    }

    suspend fun currentUserId(): String? = clientOrNull()?.auth?.currentUserOrNull()?.id

    /** Shared client for the single Realtime channel owned by the foreground service. */
    internal fun clientForRealtime(): SupabaseClient? = clientOrNull()

    fun close() {
        synchronized(this) {
            client = null
        }
    }

    private fun requireClient(): SupabaseClient =
        clientOrNull() ?: throw IllegalStateException("Remote configuration is not enabled")

    private fun clientOrNull(): SupabaseClient? {
        client?.let { return it }
        if (!configStore.canStartRemoteWork()) return null
        val config = configStore.load() ?: return null
        return synchronized(this) {
            client ?: createSupabaseClient(
                supabaseUrl = config.projectUrl,
                supabaseKey = config.publishableKey,
            ) {
                install(Auth) {
                    sessionManager = EncryptedSessionManager(credentialStore)
                    autoLoadFromStorage = true
                }
                install(Postgrest)
                install(Realtime)
            }.also { client = it }
        }
    }

    private suspend fun <T> guarded(block: suspend () -> T): T = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        throw RemoteException(mapError(e), e)
    }

    private fun mapError(error: Throwable): RemoteError = when (error) {
        is RestException -> RemoteErrors.classify(
            statusCode = error.statusCode,
            sqlState = (error as? PostgrestRestException)?.code,
            isNetwork = false,
            message = error.error,
        )
        is IOException -> RemoteError.Network
        else -> RemoteErrors.classify(
            statusCode = null,
            sqlState = null,
            isNetwork = false,
            message = error.message,
        )
    }
}
