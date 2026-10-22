package me.lucky.wasted.p2p.database

import android.content.Context
import android.content.SharedPreferences
import me.lucky.wasted.security.TinkEncryptedSharedPreferences
import java.security.SecureRandom

/** Passphrase for the SQLCipher-encrypted P2P database, wrapped by Tink/Keystore. */
class P2PDatabaseKeyStore(private val prefs: SharedPreferences) {
    companion object {
        private const val FILE_NAME = "wasted_p2p_database_key"
        private const val KEY_PASSPHRASE = "passphrase"
        private const val PASSPHRASE_BYTES = 32

        fun new(context: Context): P2PDatabaseKeyStore = P2PDatabaseKeyStore(
            TinkEncryptedSharedPreferences.create(
                context.applicationContext,
                FILE_NAME,
            ),
        )
    }

    val passphrase: ByteArray
        get() = synchronized(this) {
            val existing = prefs.getString(KEY_PASSPHRASE, null)?.hexToBytes()
            if (existing != null && existing.size == PASSPHRASE_BYTES) return existing

            val generated = ByteArray(PASSPHRASE_BYTES).also { SecureRandom().nextBytes(it) }
            prefs.edit().putString(KEY_PASSPHRASE, generated.toHex()).commit()
            generated
        }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private fun String.hexToBytes(): ByteArray? {
        if (length % 2 != 0) return null
        return try {
            ByteArray(length / 2) { index ->
                substring(index * 2, index * 2 + 2).toInt(16).toByte()
            }
        } catch (_: NumberFormatException) {
            null
        }
    }
}
