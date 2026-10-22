package me.lucky.wasted.p2p.database

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import me.lucky.wasted.p2p.models.Peer
import net.zetetic.database.sqlcipher.SupportOpenHelperFactory

/**
 * SQLCipher-encrypted Room database for P2P peer state. Existing plaintext rows from the previous
 * database are imported once and then the legacy file is removed.
 */
@Database(
    entities = [Peer::class],
    version = 1,
    exportSchema = false
)
abstract class WastedP2PDatabase : RoomDatabase() {
    abstract fun peerDao(): PeerDao

    companion object {
        private const val DATABASE_NAME = "wasted_p2p_secure.db"
        private const val LEGACY_DATABASE_NAME = "wasted_p2p.db"
        private const val TAG = "P2PDatabase"

        @Volatile
        private var instance: WastedP2PDatabase? = null

        fun getInstance(context: Context): WastedP2PDatabase =
            instance ?: synchronized(this) {
                instance ?: buildDatabase(context).also { instance = it }
            }

        private fun buildDatabase(context: Context): WastedP2PDatabase {
            Log.d(TAG, "Creating encrypted P2P database")
            System.loadLibrary("sqlcipher")
            val passphrase = P2PDatabaseKeyStore.new(context.applicationContext).passphrase
            return Room.databaseBuilder(
                context.applicationContext,
                WastedP2PDatabase::class.java,
                DATABASE_NAME
            )
                .openHelperFactory(SupportOpenHelperFactory(passphrase))
                .addCallback(object : Callback() {
                    override fun onOpen(db: SupportSQLiteDatabase) {
                        importLegacyPeers(context.applicationContext, db)
                    }
                })
                .build()
                .also { Log.d(TAG, "Encrypted P2P database created") }
        }

        private fun importLegacyPeers(context: Context, db: SupportSQLiteDatabase) {
            val legacy = context.getDatabasePath(LEGACY_DATABASE_NAME)
            if (!legacy.exists()) return

            try {
                SQLiteDatabase.openDatabase(
                    legacy.path,
                    null,
                    SQLiteDatabase.OPEN_READONLY,
                ).use { old ->
                    val cursor: android.database.Cursor = old.rawQuery(
                        "SELECT deviceId, deviceName, ipAddress, port, certificateHash, " +
                            "pairedAt, lastSeen, isConnected, pinHash FROM peers",
                        null,
                    )
                    cursor.use { c ->
                        while (c.moveToNext()) {
                            db.execSQL(
                                "INSERT OR REPLACE INTO peers " +
                                    "(deviceId, deviceName, ipAddress, port, certificateHash, " +
                                    "pairedAt, lastSeen, isConnected, pinHash) " +
                                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                arrayOf<Any?>(
                                    c.getString(0),
                                    c.getString(1),
                                    c.getString(2),
                                    c.getInt(3),
                                    c.getString(4),
                                    // Legacy hashes were APK signatures, not TLS pins. Keep the peer
                                    // row but require a fresh pairing so no unverified pin is trusted.
                                    0L,
                                    c.getLong(6),
                                    0,
                                    "",
                                ),
                            )
                        }
                    }
                }
                SQLiteDatabase.deleteDatabase(legacy)
                Log.i(TAG, "Legacy plaintext P2P database imported and removed")
            } catch (e: Exception) {
                Log.e(TAG, "Legacy P2P database import failed; keeping it for retry", e)
            }
        }
    }
}
