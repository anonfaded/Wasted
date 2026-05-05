package me.lucky.wasted.admin

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.UserManager
import android.provider.MediaStore
import java.lang.Exception

import me.lucky.wasted.Preferences

class DeviceAdminManager(private val ctx: Context) {
    data class ResetSupport(
        val isSupported: Boolean,
        val userMessage: String,
    )

    private val dpm = ctx.getSystemService(DevicePolicyManager::class.java)
    private val userManager = ctx.getSystemService(UserManager::class.java)
    private val deviceAdmin by lazy { ComponentName(ctx, DeviceAdminReceiver::class.java) }
    private val prefs by lazy { Preferences.new(ctx) }
    private val adminComponentName by lazy { deviceAdmin.flattenToShortString() }

    fun remove() = dpm?.removeActiveAdmin(deviceAdmin)
    fun isActive() = dpm?.isAdminActive(deviceAdmin) ?: false
    fun isDeviceOwner() = dpm?.isDeviceOwnerApp(ctx.packageName) == true
    fun isProfileOwner() = dpm?.isProfileOwnerApp(ctx.packageName) == true

    fun getManagementSummary(): String {
        return when {
            isDeviceOwner() -> "Wasted is enrolled as Device Owner on this phone"
            isOrgOwnedProfileOwner() -> "Wasted manages this phone as an organization-owned profile owner"
            isProfileOwner() -> "Wasted is enrolled as a profile owner on this phone"
            isActive() -> "Wasted has legacy Device Admin on this phone"
            else -> "Wasted is not enrolled on this phone"
        }
    }

    fun lockNow() { if (!lockPrivilegedNow()) dpm?.lockNow() }

    fun getResetSupport(): ResetSupport {
        if (!isActive()) {
            return ResetSupport(
                isSupported = false,
                userMessage = "Device Admin is not active on this phone.",
            )
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return ResetSupport(
                isSupported = true,
                userMessage = "Reset is available on this phone.",
            )
        }

        if (canUseFullDeviceWipeApi()) {
            return ResetSupport(
                isSupported = true,
                userMessage = "Full factory reset is available on this phone (Device Owner mode).",
            )
        }

        // On Android 14+ as device admin: best-effort file/data wipe
        return ResetSupport(
            isSupported = true,
            userMessage = "Partial wipe available: deletes photos, videos, downloads and other user files. Requires granting \"All files access\" to Wasted (Settings > Apps > Special app access > All files access). For full factory reset, enroll Wasted as Device Owner.",
        )
    }

    private fun lockPrivilegedNow(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        var ok = true
        try {
            dpm?.getParentProfileInstance(deviceAdmin)?.lockNow()
        } catch (exc: SecurityException) { ok = false }
        if (!ok || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        try {
            dpm?.lockNow(DevicePolicyManager.FLAG_EVICT_CREDENTIAL_ENCRYPTION_KEY)
        } catch (exc: Exception) { ok = false }
        return ok
    }

    fun wipeData() {
        val resetSupport = getResetSupport()
        if (!resetSupport.isSupported) {
            throw IllegalStateException(resetSupport.userMessage)
        }

        if (canUseFullDeviceWipeApi()) {
            hardReset()
            return
        }

        // For device admin on Android 14+: attempt deep manual wipe
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            deepManualWipe()
            return
        }

        // Fallback for older Android: use wipeData API
        dpm?.wipeData(buildLegacyWipeFlags())
    }

    private fun hardReset() {
        // Source: https://stackoverflow.com/a/78489105 (CC BY-SA 4.0)
        // Use appropriate wipeDevice/wipeData API based on Android version
        try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                    dpm?.wipeDevice(buildWipeDeviceFlags())
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                    dpm?.wipeData(buildLegacyWipeFlags().or(DevicePolicyManager.WIPE_RESET_PROTECTION_DATA))
                }
                else -> {
                    dpm?.wipeData(0)
                }
            }
        } catch (e: SecurityException) {
            throw IllegalStateException("Device Owner wipe failed: ${e.message}", e)
        }
    }

    private fun deepManualWipe() {
        // For device admin on Android 14+: best-effort cleanup.
        // Requires MANAGE_EXTERNAL_STORAGE to be granted by user (one-time in Settings).
        // Cannot silently uninstall apps without Device Owner — skipped.
        // Cannot touch system apps or /data/data — those require Device Owner.

        // 1. Delete our own app data (no permissions required)
        try {
            ctx.dataDir.deleteRecursively()
        } catch (_: Exception) {}
        try {
            ctx.cacheDir.deleteRecursively()
        } catch (_: Exception) {}

        // 2. Delete user files from external storage if MANAGE_EXTERNAL_STORAGE is granted
        if (hasManageExternalStoragePermission()) {
            deleteUserFiles()
        }
    }

    private fun hasManageExternalStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ctx.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    private fun deleteUserFiles() {
        val dirs = listOf(
            Environment.DIRECTORY_DOWNLOADS,
            Environment.DIRECTORY_DCIM,
            Environment.DIRECTORY_DOCUMENTS,
            Environment.DIRECTORY_PICTURES,
            Environment.DIRECTORY_MOVIES,
            Environment.DIRECTORY_MUSIC,
            Environment.DIRECTORY_ALARMS,
            Environment.DIRECTORY_NOTIFICATIONS,
            Environment.DIRECTORY_PODCASTS,
            Environment.DIRECTORY_RINGTONES,
            Environment.DIRECTORY_SCREENSHOTS,
        )
        for (dirName in dirs) {
            try {
                Environment.getExternalStoragePublicDirectory(dirName)
                    ?.takeIf { it.exists() }
                    ?.deleteRecursively()
            } catch (_: Exception) {}
        }
        // Also wipe the root of external storage (catches app-created directories)
        try {
            Environment.getExternalStorageDirectory()?.listFiles()?.forEach { child ->
                if (child.isDirectory && dirs.none { child.name.equals(it, ignoreCase = true) }) {
                    child.deleteRecursively()
                }
            }
        } catch (_: Exception) {}
    }

    fun makeRequestIntent() =
        Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
            .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, deviceAdmin)

    private fun canUseFullDeviceWipeApi(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return false
        }

        val isDeviceOwner = isDeviceOwner()
        val isOrgOwnedProfileOwner = isOrgOwnedProfileOwner()

        return isDeviceOwner || isOrgOwnedProfileOwner
    }

    private fun isOrgOwnedProfileOwner(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            isProfileOwner() &&
            dpm?.isOrganizationOwnedDeviceWithManagedProfile == true
    }

    private fun buildLegacyWipeFlags(): Int {
        var flags = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            flags = flags.or(DevicePolicyManager.WIPE_SILENTLY)
        }
        return flags
    }

    private fun buildWipeDeviceFlags(): Int {
        var flags = buildLegacyWipeFlags()
        if (prefs.isWipeEmbeddedSim && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            flags = flags.or(DevicePolicyManager.WIPE_EUICC)
        }
        return flags
    }
}