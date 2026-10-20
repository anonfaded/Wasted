package me.lucky.wasted.remote.data

import android.util.Log

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.postgrest

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

import me.lucky.wasted.remote.domain.ClaimEnrollmentParams
import me.lucky.wasted.remote.domain.ReconcileParams
import me.lucky.wasted.remote.domain.RemoteCommandDto
import me.lucky.wasted.remote.domain.RemoteDeviceDto
import me.lucky.wasted.remote.domain.RemoteReconcileResponse
import me.lucky.wasted.remote.domain.TransitionCommandParams

/**
 * The only place that touches the Supabase client. The client is created lazily and only when
 * the fail-closed configuration boundary is open; a fresh or unconfigured install performs
 * zero network work.
 */
class SupabaseRemoteRepository(
    private val configStore: RemoteConfigStore,
    private val credentialStore: RemoteCredentialStore,
) {
    companion object {
        private const val TAG = "SupabaseRemote"
        private val json = Json { encodeDefaults = true }
    }

    @Volatile
    private var client: SupabaseClient? = null

    val isAvailable: Boolean
        get() = configStore.canStartRemoteWork()

    suspend fun ensureAnonymousSession() {
        val supabase = requireClient()
        if (supabase.auth.currentSessionOrNull() == null) {
            supabase.auth.signInAnonymously()
            Log.i(TAG, "Anonymous device session established")
        }
    }

    suspend fun claimEnrollment(params: ClaimEnrollmentParams): RemoteDeviceDto {
        Log.d(TAG, "claim_device_enrollment")
        val body = json.encodeToJsonElement(ClaimEnrollmentParams.serializer(), params).jsonObject
        return requireClient().postgrest.rpc("claim_device_enrollment", body)
            .decodeAs<RemoteDeviceDto>()
    }

    suspend fun reconcile(params: ReconcileParams): RemoteReconcileResponse {
        val body = json.encodeToJsonElement(ReconcileParams.serializer(), params).jsonObject
        return requireClient().postgrest.rpc("device_reconcile", body)
            .decodeAs<RemoteReconcileResponse>()
    }

    suspend fun transitionCommand(params: TransitionCommandParams): RemoteCommandDto {
        Log.d(
            TAG,
            "device_transition_command ${params.commandId} ${params.expectedState} -> ${params.newState}",
        )
        val body = json.encodeToJsonElement(TransitionCommandParams.serializer(), params).jsonObject
        return requireClient().postgrest.rpc("device_transition_command", body)
            .decodeAs<RemoteCommandDto>()
    }

    suspend fun currentUserId(): String? = clientOrNull()?.auth?.currentUserOrNull()?.id

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
            }.also { client = it }
        }
    }
}
