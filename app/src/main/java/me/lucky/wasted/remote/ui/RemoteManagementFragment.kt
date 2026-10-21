package me.lucky.wasted.remote.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.content.ContextCompat
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
import me.lucky.wasted.R
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
import me.lucky.wasted.remote.domain.RemoteError
import me.lucky.wasted.remote.domain.RemoteException
import me.lucky.wasted.remote.domain.SyncOutcome
import me.lucky.wasted.trigger.shared.NotificationManager
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

class RemoteManagementFragment : Fragment() {

    private lateinit var binding: FragmentRemoteManagementBinding
    private lateinit var prefs: Preferences
    private lateinit var configStore: RemoteConfigStore
    private lateinit var credentials: RemoteCredentialStore
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var defaultDashboardStrokeColor = 0
    private var defaultDashboardStatusColor = 0

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View {
        binding = FragmentRemoteManagementBinding.inflate(inflater, container, false)
        defaultDashboardStrokeColor = binding.websiteUrl.boxStrokeColor
        defaultDashboardStatusColor = binding.dashboardStatus.currentTextColor
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
        deviceName.editText?.setText(Build.MODEL ?: "")
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
        val config = configStore.load()
        if (config != null) {
            if (binding.projectUrl.editText?.text.isNullOrBlank()) {
                binding.projectUrl.editText?.setText(config.projectUrl)
            }
            if (binding.publishableKey.editText?.text.isNullOrBlank()) {
                binding.publishableKey.editText?.setText(config.publishableKey)
            }
            if (binding.websiteUrl.editText?.text.isNullOrBlank()) {
                binding.websiteUrl.editText?.setText(config.websiteUrl)
            }
            refreshState()
            return
        }
        val draft = configStore.loadDraft() ?: return
        if (binding.projectUrl.editText?.text.isNullOrBlank()) {
            binding.projectUrl.editText?.setText(draft.projectUrl)
        }
        if (binding.publishableKey.editText?.text.isNullOrBlank()) {
            binding.publishableKey.editText?.setText(draft.publishableKey)
        }
        refreshState()
    }

    private fun setup() = with(binding) {
        setupWizard.setOnClickListener {
            startActivity(Intent(requireContext(), RemoteSetupActivity::class.java))
        }
        saveConfig.setOnClickListener { saveConfig() }
        testConnection.setOnClickListener { testConnection() }
        testDashboard.setOnClickListener { testDashboard() }
        openSupabase.setOnClickListener { openUrl("https://supabase.com/dashboard") }
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
        val config = configStore.load()
        val draft = if (config == null) configStore.loadDraft() else null
        enableRemote.isChecked = configStore.remoteEnabled
        debugMode.isChecked = prefs.isDebugMode
        notifications.isChecked = credentials.notificationsEnabled
        enrollmentSection.visibility = if (configStore.remoteEnabled) View.VISIBLE else View.GONE
        openWebsite.isEnabled = !config?.websiteUrl.isNullOrBlank()

        val message = buildString {
            if (config == null) {
                if (draft != null) {
                    append("Project details saved. Next: host the dashboard, paste its URL under 2. Dashboard URL, and tap Save connection.")
                } else {
                    append("Not set up yet. Start with the setup wizard below.")
                }
            } else {
                append("Connection saved.")
                if (!credentials.enrolled) {
                    append("\nNext: enable Remote Management and claim an enrollment token.")
                } else {
                    append("\nThis device is enrolled.")
                }
            }
            val lastSync = credentials.lastSyncAt
            if (lastSync > 0) {
                append("\nLast successful sync: ")
                append(java.text.DateFormat.getDateTimeInstance()
                    .format(java.util.Date(lastSync)))
            }
            if (configStore.remoteEnabled && credentials.enrolled) {
                append("\nRemote sync is active while this device is unlocked.")
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
            snackbar("Save the connection details first.")
            return
        }
        snackbar("Testing Supabase connection…")
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                val repository = SupabaseRemoteRepository(configStore, credentials)
                try {
                    Result.success(repository.testConnection())
                } catch (e: RemoteException) {
                    Result.failure(e)
                } catch (e: Exception) {
                    Result.failure(e)
                } finally {
                    repository.close()
                }
            }
            result.fold(
                onSuccess = { anonymousEnabled ->
                    if (anonymousEnabled) {
                        snackbar("Supabase connection OK. Anonymous sign-ins are enabled.")
                    } else {
                        showAnonymousSignInsDialog()
                    }
                },
                onFailure = { error ->
                    val message = when (error) {
                        is RemoteException ->
                            "Supabase connection failed: ${connectionErrorMessage(error.error)}"
                        else ->
                            "Supabase connection failed: ${error.message ?: "unknown error"}"
                    }
                    snackbar(message)
                },
            )
        }
    }

    private fun showAnonymousSignInsDialog() {
        MaterialAlertDialogBuilder(requireContext())
            .setTitle("Anonymous sign-ins are off")
            .setMessage(
                "Remote Management uses anonymous sign-ins to give each device its own private " +
                    "identity. That links a device to your account without storing your email or " +
                    "password on it.\n\nIf you leave this off, your owner account and dashboard " +
                    "still work, but this device cannot enroll or sync remote commands.\n\nEnable “Allow " +
                    "anonymous sign-ins” in Supabase → Authentication → Providers if you want " +
                    "Remote Management.",
            )
            .setPositiveButton("Open Auth settings") { _, _ ->
                projectAuthUrl()?.let(::openUrl)
                    ?: snackbar("Save a valid project URL first.")
            }
            .setNegativeButton("Not now", null)
            .show()
    }

    private fun projectAuthUrl(): String? {
        val config = configStore.load() ?: return null
        val host = Uri.parse(config.projectUrl).host ?: return null
        if (!host.endsWith(".supabase.co")) return null
        val ref = host.removeSuffix(".supabase.co")
        return "https://supabase.com/dashboard/project/$ref/auth/providers"
    }

    private fun testDashboard() {
        val raw = binding.websiteUrl.editText?.text?.toString()?.trim().orEmpty()
        if (raw.isEmpty()) {
            setDashboardTestVisual(false)
            binding.dashboardStatus.text = "Enter the hosted dashboard URL first."
            return
        }
        val uri = runCatching { java.net.URI(raw) }.getOrNull()
        if (uri?.scheme != "https" || uri.host.isNullOrBlank()) {
            setDashboardTestVisual(false)
            binding.dashboardStatus.text = "Enter a valid HTTPS URL."
            return
        }
        setDashboardTestVisual(false)
        binding.dashboardStatus.text = "Checking…"
        scope.launch {
            val code = withContext(Dispatchers.IO) {
                runCatching {
                    val client = OkHttpClient.Builder()
                        .connectTimeout(10, TimeUnit.SECONDS)
                        .readTimeout(10, TimeUnit.SECONDS)
                        .build()
                    client.newCall(Request.Builder().url(raw).get().build())
                        .execute()
                        .use { it.code }
                }.getOrNull()
            }
            when {
                code == null -> {
                    setDashboardTestVisual(false)
                    binding.dashboardStatus.text = "Could not reach the dashboard. Check the URL and your connection."
                }
                code in 200..299 -> {
                    setDashboardTestVisual(true)
                    binding.dashboardStatus.text = "Dashboard is reachable (HTTP $code)."
                }
                code == 401 || code == 403 -> {
                    setDashboardTestVisual(false)
                    binding.dashboardStatus.text =
                        "Dashboard responded with HTTP $code. Netlify Drop sites are password-protected until claimed. Open the site, click Claim this site, then test again."
                }
                code == 404 -> {
                    setDashboardTestVisual(false)
                    binding.dashboardStatus.text =
                        "Dashboard responded with HTTP 404. Make sure the uploaded file is named index.html at the site root."
                }
                else -> {
                    setDashboardTestVisual(false)
                    binding.dashboardStatus.text = "Dashboard responded with HTTP $code."
                }
            }
        }
    }

    private fun setDashboardTestVisual(success: Boolean) {
        val green = ContextCompat.getColor(requireContext(), R.color.green_500)
        binding.websiteUrl.setBoxStrokeColor(
            if (success) green else defaultDashboardStrokeColor,
        )
        binding.dashboardStatus.setTextColor(
            if (success) green else defaultDashboardStatusColor,
        )
    }

    private fun connectionErrorMessage(error: RemoteError): String = when (error) {
        RemoteError.Network -> "network unavailable. Check your internet connection."
        is RemoteError.RateLimited ->
            "Supabase rate-limited the request. Wait a minute and try again."
        is RemoteError.Server ->
            "Supabase server error (${error.statusCode}). Try again shortly."
        RemoteError.Authentication ->
            "Supabase rejected the key. Check the Project URL and publishable key."
        RemoteError.RlsDenied ->
            "Supabase denied access. Check that setup.sql ran successfully."
        RemoteError.Conflict ->
            "Supabase reported a configuration conflict."
        RemoteError.Validation ->
            "Supabase rejected the request. Check the Project URL and publishable key, and make sure the backend setup is complete."
        is RemoteError.Unknown ->
            "unexpected Supabase error. Check the Project URL/key and Auth settings."
    }

    private fun openWebsite() {
        val url = configStore.load()?.websiteUrl
        if (url.isNullOrBlank()) {
            snackbar("Host the generated dashboard first, then save its HTTPS URL here.")
            return
        }
        openUrl(url)
    }

    private fun openUrl(url: String) {
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
                snackbar("Save the project URL, publishable key, and dashboard URL first (or use the setup wizard).")
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
        val deviceName = binding.deviceName.editText?.text?.toString()?.trim()
            .orEmpty()
            .ifBlank { Build.MODEL ?: "Android device" }
            .take(80)
        scope.launch {
            val message = withContext(Dispatchers.IO) {
                val repository = SupabaseRemoteRepository(configStore, credentials)
                try {
                    repository.ensureAnonymousSession()
                    val device = repository.claimEnrollment(
                        ClaimEnrollmentParams(
                            token = token,
                            installationId = credentials.installationId,
                            deviceName = deviceName,
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
