package me.lucky.wasted.remote.domain

import com.google.gson.JsonParser
import java.io.ByteArrayOutputStream
import java.net.URI

data class RemoteConfig(
    val projectUrl: String,
    val publishableKey: String,
    val websiteUrl: String,
)

enum class RemoteConfigField {
    PROJECT_URL,
    PUBLISHABLE_KEY,
    WEBSITE_URL,
}

data class RemoteConfigError(
    val field: RemoteConfigField,
    val message: String,
)

object RemoteConfigValidator {
    const val MAX_URL_LENGTH = 512
    const val MAX_KEY_LENGTH = 2048

    private const val PUBLISHABLE_KEY_PREFIX = "sb_publishable_"
    private const val SECRET_KEY_PREFIX = "sb_secret_"
    private const val JWT_PREFIX = "eyJ"

    private const val BASE64URL_ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    fun validate(
        projectUrl: String,
        publishableKey: String,
        websiteUrl: String,
    ): List<RemoteConfigError> = buildList {
        validateWebUrl(projectUrl, MAX_URL_LENGTH)?.let {
            add(RemoteConfigError(RemoteConfigField.PROJECT_URL, it))
        }
        validatePublishableKey(publishableKey)?.let {
            add(RemoteConfigError(RemoteConfigField.PUBLISHABLE_KEY, it))
        }
        validateWebUrl(websiteUrl, MAX_URL_LENGTH)?.let {
            add(RemoteConfigError(RemoteConfigField.WEBSITE_URL, it))
        }
    }

    private fun validateWebUrl(value: String, maxLength: Int): String? {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return "Required"
        if (trimmed.length > maxLength) return "Must be at most $maxLength characters"

        val uri = try {
            URI(trimmed)
        } catch (_: Exception) {
            return "Not a valid URL"
        }

        if (uri.scheme?.lowercase() != "https") return "Must be an https:// URL"
        if (uri.host.isNullOrEmpty()) return "Must include a host"
        if (uri.userInfo != null) return "Must not contain credentials"
        if (uri.rawQuery != null || uri.rawFragment != null) return "Must not contain a query or fragment"
        return null
    }

    private fun validatePublishableKey(value: String): String? {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return "Required"
        if (trimmed.length > MAX_KEY_LENGTH) return "Must be at most $MAX_KEY_LENGTH characters"
        if (trimmed.startsWith(SECRET_KEY_PREFIX)) return "Secret keys must never be stored in the app"

        if (trimmed.startsWith(PUBLISHABLE_KEY_PREFIX)) {
            return if (trimmed.length > PUBLISHABLE_KEY_PREFIX.length) null else "Invalid publishable key"
        }

        if (trimmed.startsWith(JWT_PREFIX)) return validateLegacyAnonKey(trimmed)

        return "Not a Supabase publishable key"
    }

    private fun validateLegacyAnonKey(token: String): String? {
        val parts = token.split('.')
        if (parts.size != 3) return "Malformed key"

        val payload = decodeBase64Url(parts[1])?.toString(Charsets.UTF_8) ?: return "Malformed key"

        val role = try {
            JsonParser.parseString(payload).asJsonObject.get("role")?.asString
        } catch (_: Exception) {
            return "Malformed key"
        }

        return when (role) {
            "anon" -> null
            "service_role" -> "Secret keys must never be stored in the app"
            else -> "Not an anonymous Supabase key"
        }
    }

    private fun decodeBase64Url(value: String): ByteArray? {
        val cleaned = value.trimEnd('=')
        val out = ByteArrayOutputStream()
        var buffer = 0
        var bits = 0
        for (ch in cleaned) {
            val index = BASE64URL_ALPHABET.indexOf(ch)
            if (index < 0) return null
            buffer = (buffer shl 6) or index
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.write((buffer shr bits) and 0xFF)
            }
        }
        return out.toByteArray()
    }
}
