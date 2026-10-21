package me.lucky.wasted.remote.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

import me.lucky.wasted.Preferences
import me.lucky.wasted.Trigger
import me.lucky.wasted.Utils
import me.lucky.wasted.databinding.FragmentRemoteManagementBinding
import me.lucky.wasted.remote.RemoteEngine
import me.lucky.wasted.remote.data.RemoteConfigStore
import me.lucky.wasted.remote.data.RemoteCredentialStore
import me.lucky.wasted.remote.data.RemoteDatabase
import me.lucky.wasted.remote.data.SupabaseRemoteRepository
import me.lucky.wasted.remote.domain.ClaimEnrollmentParams
import me.lucky.wasted.remote.domain.RemoteConfig
import me.lucky.wasted.remote.domain.RemoteConfigError
import me.lucky.wasted.remote.domain.RemoteConfigField
import me.lucky.wasted.remote.domain.RemoteConfigValidator
import me.lucky.wasted.remote.domain.SyncOutcome
import me.lucky.wasted.trigger.shared.NotificationManager

class RemoteManagementFragment : Fragment() {

    private lateinit var binding: FragmentRemoteManagementBinding
    private lateinit var prefs: Preferences
    private lateinit var configStore: RemoteConfigStore
    private lateinit var credentials: RemoteCredentialStore
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View {
        binding = FragmentRemoteManagementBinding.inflate(inflater, container, false)
        prefs = Preferences.new(requireContext())
        configStore = RemoteConfigStore.new(requireContext())
        credentials = RemoteCredentialStore.new(requireContext())
        init()
        setup()
        return binding.root
    }

    override fun onDestroyView() {
        super.onDestroyView()
        scope.cancel()
    }

    private fun init() = with(binding) {
        configStore.load()?.let { config ->
            projectUrl.editText?.setText(config.projectUrl)
            publishableKey.editText?.setText(config.publishableKey)
            websiteUrl.editText?.setText(config.websiteUrl)
        } ?: configStore.loadDraft()?.let { draft ->
            projectUrl.editText?.setText(draft.projectUrl)
            publishableKey.editText?.setText(draft.publishableKey)
        }
        refreshState()
    }

    override fun onResume() {
        super.onResume()
        if (configStore.isConfigured) return
        val draft = configStore.loadDraft() ?: return
        if (binding.projectUrl.editText?.text.isNullOrBlank()) {
            binding.projectUrl.editText?.setText(draft.projectUrl)
        }
        if (binding.publishableKey.editText?.text.isNullOrBlank()) {
            binding.publishableKey.editText?.setText(draft.publishableKey)
        }
    }

    private fun setup() = with(binding) {
        setupWizard.setOnClickListener {
            startActivity(Intent(requireContext(), RemoteSetupActivity::class.java))
        }
        saveConfig.setOnClickListener { saveConfig() }
        testConnection.setOnClickListener { testConnection() }
        openWebsite.setOnClickListener { openWebsite() }
        claimEnrollment.setOnClickListener { claimEnrollment() }
        manualSync.setOnClickListener { manualSync() }
        resetEnrollment.setOnClickListener { confirmResetEnrollment() }
        attachListeners()
    }

    private fun attachListeners() = with(binding) {
        enableRemote.setOnCheckedChangeListener { _, checked -> setRemoteEnabled(checked) }
        debugMode.setOnCheckedChangeListener { _, checked -> setDebugMode(checked) }
        notifications.setOnCheckedChangeListener { _, checked ->
            credentials.notificationsEnabled = checked
        }
    }

    private fun detachListeners() = with(binding) {
        enableRemote.setOnCheckedChangeListener(null)
        debugMode.setOnCheckedChangeListener(null)
        notifications.setOnCheckedChangeListener(null)
    }

    private fun refreshState() = with(binding) {
        detachListeners()
        enableRemote.isChecked = configStore.remoteEnabled
        debugMode.isChecked = prefs.isDebugMode
        notifications.isChecked = credentials.notificationsEnabled
        enrollmentSection.visibility = if (configStore.remoteEnabled) View.VISIBLE else View.GONE

        val message = buildString {
            if (!configStore.isConfigured) {
                append("Configuration: not saved yet.")
            } else {
                append("Configuration: saved.")
            }
            when {
                !credentials.enrolled -> append("\nDevice: not enrolled.")
                else -> {
                    append("\nDevice: ")
                    append(credentials.deviceId ?: "unknown")
                    append(" (account ")
                    append(credentials.accountId ?: "unknown")
                    append(")")
                }
            }
            val lastSync = credentials.lastSyncAt
            if (lastSync > 0) {
                append("\nLast successful sync: ")
                append(java.text.DateFormat.getDateTimeInstance()
                    .format(java.util.Date(lastSync)))
            }
            if (configStore.remoteEnabled && credentials.enrolled) {
                append("\nRemote sync is active while the app is unlocked.")
            }
        }
        enrollmentStatus.text = message
        attachListeners()
    }

    private fun saveConfig() = with(binding) {
        val config = RemoteConfig(
            projectUrl = projectUrl.editText?.text?.toString().orEmpty(),
            publishableKey = publishableKey.editText?.text?.toString().orEmpty(),
            websiteUrl = websiteUrl.editText?.text?.toString().orEmpty(),
        )
        val errors = RemoteConfigValidator.validate(
            config.projectUrl,
            config.publishableKey,
            config.websiteUrl,
        )
        applyFieldErrors(errors)
        if (errors.isNotEmpty()) {
            snackbar("Fix the highlighted fields.")
            return
        }
        if (configStore.save(config)) {
            snackbar("Configuration saved.")
            refreshState()
        } else {
            snackbar("Configuration could not be saved.")
        }
    }

    private fun applyFieldErrors(errors: List<RemoteConfigError>) = with(binding) {
        projectUrl.error = null
        publishableKey.error = null
        websiteUrl.error = null
        for (error in errors) {
            when (error.field) {
                RemoteConfigField.PROJECT_URL -> projectUrl.error = error.message
                RemoteConfigField.PUBLISHABLE_KEY -> publishableKey.error = error.message
                RemoteConfigField.WEBSITE_URL -> websiteUrl.error = error.message
            }
        }
    }

    private fun testConnection() {
        if (!configStore.isConfigured) {
            snackbar("Save a valid configuration first.")
            return
        }
        snackbar("Testing connection…")
        scope.launch {
            val message = withContext(Dispatchers.IO) {
                val repository = SupabaseRemoteRepository(configStore, credentials)
                try {
                    repository.ensureAnonymousSession()
                    "Connection OK."
                } catch (e: Exception) {
                    "Connection failed: ${e.message}"
                } finally {
                    repository.close()
                }
            }
            snackbar(message)
        }
    }

    private fun openWebsite() {
        val url = configStore.load()?.websiteUrl
        if (url.isNullOrBlank()) {
            snackbar("Save a valid website URL first.")
            return
        }
        runCatching {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        }.onFailure {
            snackbar("No browser available.")
        }
    }

    private fun setRemoteEnabled(enabled: Boolean) {
        if (enabled) {
            if (!configStore.isConfigured) {
                detachListeners()
                binding.enableRemote.isChecked = false
                attachListeners()
                snackbar("Save a valid configuration before enabling.")
                return
            }
            // First enablement locally forces Debug Mode ON before enrollment.
            prefs.isDebugMode = true
        } else {
            credentials.session = null
        }
        configStore.remoteEnabled = enabled
        Utils(requireContext()).updateForegroundRequiredEnabled()
        refreshState()
    }

    private fun setDebugMode(enabled: Boolean) {
        if (enabled) {
            prefs.isDebugMode = true
            refreshState()
            return
        }
        MaterialAlertDialogBuilder(requireContext())
            .setTitle("Turn Debug Mode OFF?")
            .setMessage(
                "While Debug Mode is OFF, dangerous commands (including a remote " +
                    "Force Reset) can wipe this device. Only turn it off when you are " +
                    "ready for real destructive actions.",
            )
            .setPositiveButton("Turn OFF") { _, _ ->
                prefs.isDebugMode = false
                refreshState()
            }
            .setNegativeButton(android.R.string.cancel) { _, _ ->
                refreshState()
            }
            .setCancelable(false)
            .show()
    }

    private fun claimEnrollment() {
        if (!configStore.remoteEnabled) {
            snackbar("Enable Remote Management first.")
            return
        }
        val token = binding.enrollmentToken.editText?.text?.toString()?.trim().orEmpty()
        if (token.length != 64 || token.any { it !in "0123456789abcdef" }) {
            binding.enrollmentToken.error = "Enter the 64-character lowercase hex token"
            return
        }
        binding.enrollmentToken.error = null
        scope.launch {
            val message = withContext(Dispatchers.IO) {
                val repository = SupabaseRemoteRepository(configStore, credentials)
                try {
                    repository.ensureAnonymousSession()
                    val device = repository.claimEnrollment(
                        ClaimEnrollmentParams(
                            token = token,
                            installationId = credentials.installationId,
                            deviceName = Build.MODEL ?: "Android device",
                            lockTimerMinutes = prefs.triggerLockCount,
                            usbTriggerEnabled = prefs.triggers.and(Trigger.USB.value) != 0,
                        ),
                    )
                    credentials.deviceId = device.id
                    credentials.accountId = device.accountId
                    credentials.enrolled = true
                    credentials.appliedSettingsRevision = 0
                    "Enrolled as ${device.name}."
                } catch (e: Exception) {
                    "Enrollment failed: ${e.message}"
                } finally {
                    repository.close()
                }
            }
            snackbar(message)
            refreshState()
        }
    }

    private fun manualSync() {
        if (!configStore.canStartRemoteWork() || !credentials.enrolled) {
            snackbar("Enable Remote Management and enroll first.")
            return
        }
        snackbar("Syncing…")
        val ctx = requireContext()
        scope.launch {
            val message = withContext(Dispatchers.IO) {
                val engine = RemoteEngine.create(ctx)
                if (engine == null) {
                    "Remote is not available."
                } else {
                    try {
                        when (val outcome = engine.runSync()) {
                            is SyncOutcome.Success -> {
                                if (credentials.notificationsEnabled) {
                                    NotificationManager(ctx).notifyRemoteEvent(
                                        1002,
                                        "Remote sync complete",
                                        "Manual sync finished successfully.",
                                    )
                                }
                                "Sync complete."
                            }
                            is SyncOutcome.Failed -> "Sync failed: ${outcome.reason}"
                            SyncOutcome.NotConfigured -> "Remote is not configured."
                            SyncOutcome.NotEnrolled -> "Device is not enrolled."
                            SyncOutcome.Coalesced -> "A sync is already running."
                        }
                    } catch (e: Exception) {
                        "Sync failed: ${e.message}"
                    } finally {
                        engine.close()
                    }
                }
            }
            snackbar(message)
            refreshState()
        }
    }

    private fun confirmResetEnrollment() {
        MaterialAlertDialogBuilder(requireContext())
            .setTitle("Reset Remote Enrollment?")
            .setMessage(
                "This stops remote sync, clears the device session and the encrypted " +
                    "remote journal/outbox, and rotates this device's installation ID. " +
                    "A fresh enrollment token from the dashboard is required. Local " +
                    "settings, timers, Device Admin, and P2P are not affected.",
            )
            .setPositiveButton("Reset") { _, _ ->
                credentials.clearSession()
                credentials.rotateInstallationId()
                configStore.remoteEnabled = false
                RemoteDatabase.clear(requireContext())
                Utils(requireContext()).updateForegroundRequiredEnabled()
                snackbar("Remote enrollment reset.")
                refreshState()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun snackbar(message: String) {
        Snackbar.make(binding.root, message, Snackbar.LENGTH_LONG).show()
    }
}
