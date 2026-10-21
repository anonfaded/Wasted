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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

import okhttp3.OkHttpClient
import okhttp3.Request

import java.util.concurrent.TimeUnit

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

    private val httpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()
    }

    val isAvailable: Boolean
        get() = configStore.canStartRemoteWork()

    override suspend fun ensureAnonymousSession() = guarded {
        val supabase = requireClient()
        if (supabase.auth.currentSessionOrNull() == null) {
            supabase.auth.signInAnonymously()
            Log.i(TAG, "Anonymous device session established")
        }
    }

    /**
     * Explicit user-triggered, read-only connectivity check. Reads the public Auth settings to
     * validate the project URL/publishable key; it does not create a user or start Realtime.
     *
     * @return true when anonymous sign-ins are enabled on the project.
     */
    suspend fun testConnection(): Boolean = withContext(Dispatchers.IO) {
        val config = configStore.load()
            ?: throw RemoteException(RemoteError.Validation)
        val endpoint = config.projectUrl.trimEnd('/') + "/auth/v1/settings"
        val request = Request.Builder()
            .url(endpoint)
            .header("apikey", config.publishableKey)
            .get()
            .build()
        val response = try {
            httpClient.newCall(request).execute()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw RemoteException(RemoteError.Network, e)
        }
        response.use {
            if (it.code == 401 || it.code == 403) {
                throw RemoteException(RemoteError.Authentication)
            }
            if (!it.isSuccessful) {
                throw RemoteException(RemoteError.Server(it.code))
            }
            val body = it.body?.string().orEmpty()
            val external = json.parseToJsonElement(body).jsonObject["external"]?.jsonObject
            val anonymous = external?.get("anonymous_users")?.jsonPrimitive?.booleanOrNull
            anonymous == true
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
