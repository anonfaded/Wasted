package me.lucky.wasted.remote.data

import android.content.Context
import android.content.SharedPreferences
import me.lucky.wasted.remote.domain.RemoteConfig
import me.lucky.wasted.remote.domain.RemoteConfigValidator
import me.lucky.wasted.security.TinkEncryptedSharedPreferences

/**
 * Fail-closed storage boundary for the remote-management configuration.
 * Values live in encrypted preferences; defaults are unconfigured and OFF.
 * Missing, partial, invalid, or corrupt state always reads as "not configured".
 */
class RemoteConfigStore(private val prefs: SharedPreferences) {
    companion object {
        private const val FILE_NAME = "remote_config_secure_prefs"
        private const val KEY_PROJECT_URL = "project_url"
        private const val KEY_PUBLISHABLE_KEY = "publishable_key"
        private const val KEY_WEBSITE_URL = "website_url"
        private const val KEY_REMOTE_ENABLED = "remote_enabled"

        fun new(ctx: Context): RemoteConfigStore = RemoteConfigStore(
            TinkEncryptedSharedPreferences.create(ctx.applicationContext, FILE_NAME),
        )
    }

    val isConfigured: Boolean
        get() = load() != null

    var remoteEnabled: Boolean
        get() = runCatching { prefs.getBoolean(KEY_REMOTE_ENABLED, false) }.getOrDefault(false)
        set(value) {
            runCatching { prefs.edit().putBoolean(KEY_REMOTE_ENABLED, value).apply() }
        }

    fun load(): RemoteConfig? = runCatching {
        val projectUrl = prefs.getString(KEY_PROJECT_URL, null) ?: return@runCatching null
        val publishableKey = prefs.getString(KEY_PUBLISHABLE_KEY, null) ?: return@runCatching null
        val websiteUrl = prefs.getString(KEY_WEBSITE_URL, null) ?: return@runCatching null

        val errors = RemoteConfigValidator.validate(projectUrl, publishableKey, websiteUrl)
        if (errors.isNotEmpty()) return@runCatching null

        RemoteConfig(projectUrl.trim(), publishableKey.trim(), websiteUrl.trim())
    }.getOrNull()

    fun save(config: RemoteConfig): Boolean = runCatching {
        val normalized = RemoteConfig(
            projectUrl = config.projectUrl.trim(),
            publishableKey = config.publishableKey.trim(),
            websiteUrl = config.websiteUrl.trim(),
        )
        val errors = RemoteConfigValidator.validate(
            normalized.projectUrl,
            normalized.publishableKey,
            normalized.websiteUrl,
        )
        if (errors.isNotEmpty()) return@runCatching false

        prefs.edit()
            .putString(KEY_PROJECT_URL, normalized.projectUrl)
            .putString(KEY_PUBLISHABLE_KEY, normalized.publishableKey)
            .putString(KEY_WEBSITE_URL, normalized.websiteUrl)
            .commit()
    }.getOrDefault(false)

    fun clearConfiguration() {
        runCatching {
            prefs.edit()
                .remove(KEY_PROJECT_URL)
                .remove(KEY_PUBLISHABLE_KEY)
                .remove(KEY_WEBSITE_URL)
                .putBoolean(KEY_REMOTE_ENABLED, false)
                .commit()
        }
    }

    fun canStartRemoteWork(): Boolean = remoteEnabled && load() != null
}
