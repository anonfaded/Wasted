package me.lucky.wasted.remote.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.snackbar.Snackbar

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

import me.lucky.wasted.databinding.ActivityRemoteSetupBinding
import me.lucky.wasted.remote.data.RemoteConfigStore
import me.lucky.wasted.remote.domain.DashboardTemplate
import me.lucky.wasted.remote.domain.RemoteConfigField
import me.lucky.wasted.remote.domain.RemoteConfigValidator
import java.net.URI

/**
 * Guided, offline setup: collect the project URL/key, provide the database SQL and Auth
 * checklist, then generate the single-file dashboard into a user-chosen SAF location.
 */
class RemoteSetupActivity : AppCompatActivity() {
    private lateinit var binding: ActivityRemoteSetupBinding
    private lateinit var configStore: RemoteConfigStore
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val createDocument =
        registerForActivityResult(ActivityResultContracts.CreateDocument("text/html")) { uri ->
            if (uri != null) writeDashboard(uri)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityRemoteSetupBinding.inflate(layoutInflater)
        setContentView(binding.root)
        configStore = RemoteConfigStore.new(this)

        configStore.loadDraft()?.let { draft ->
            binding.projectUrl.editText?.setText(draft.projectUrl)
            binding.publishableKey.editText?.setText(draft.publishableKey)
        }

        binding.openProject.setOnClickListener { openProjectPage("") }
        binding.saveDetails.setOnClickListener {
            if (saveDetails()) snackbar("Project details saved on this device.")
        }
        binding.copySetupSql.setOnClickListener { copySetupSql() }
        binding.openSqlEditor.setOnClickListener { openProjectPage("sql/new") }
        binding.openAuthSettings.setOnClickListener { openProjectPage("auth/providers") }
        binding.generateDashboard.setOnClickListener {
            if (saveDetails()) createDocument.launch("wasted-dashboard.html")
        }
        binding.openNetlify.setOnClickListener { openUrl("https://app.netlify.com/drop") }
        binding.finishSetup.setOnClickListener { finish() }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun saveDetails(): Boolean {
        binding.projectUrl.error = null
        binding.publishableKey.error = null
        val url = binding.projectUrl.editText?.text?.toString().orEmpty()
        val key = binding.publishableKey.editText?.text?.toString().orEmpty()

        val errors = RemoteConfigValidator.validateConnection(url, key)
        for (error in errors) {
            when (error.field) {
                RemoteConfigField.PROJECT_URL -> binding.projectUrl.error = error.message
                RemoteConfigField.PUBLISHABLE_KEY -> binding.publishableKey.error = error.message
                else -> Unit
            }
        }
        if (errors.isNotEmpty()) return false

        if (!configStore.saveDraft(url, key)) {
            snackbar("Could not save the project details.")
            return false
        }
        return true
    }

    private fun copySetupSql() {
        val sql = runCatching {
            assets.open("setup.sql").bufferedReader().use { it.readText() }
        }.getOrNull()
        if (sql.isNullOrBlank()) {
            snackbar("Setup SQL is unavailable in this build.")
            return
        }
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Wasted setup SQL", sql))
        snackbar("Setup SQL copied. Paste it into the Supabase SQL Editor and press Run.")
    }

    private fun openProjectPage(suffix: String) {
        val ref = projectRef()
        if (ref == null) {
            snackbar("Enter a valid Supabase project URL first.")
            return
        }
        val path = if (suffix.isEmpty()) "" else "/$suffix"
        openUrl("https://supabase.com/dashboard/project/$ref$path")
    }

    private fun projectRef(): String? {
        val raw = binding.projectUrl.editText?.text?.toString()?.trim().orEmpty()
        val host = runCatching { URI(raw).host }.getOrNull() ?: return null
        if (!host.endsWith(".supabase.co")) return null
        val ref = host.removeSuffix(".supabase.co")
        return ref.takeIf { it.matches(Regex("[a-z0-9-]+")) }
    }

    private fun openUrl(url: String) {
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
            .onFailure { snackbar("No browser available.") }
    }

    private fun writeDashboard(uri: Uri) {
        val draft = configStore.loadDraft() ?: run {
            snackbar("Save valid project details first.")
            return
        }
        val version = runCatching {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, 0).versionName
        }.getOrNull() ?: "3.0.0"

        scope.launch {
            val saved = withContext(Dispatchers.IO) {
                runCatching {
                    val template = assets.open("dashboard-template.html")
                        .bufferedReader()
                        .use { it.readText() }
                    val html = DashboardTemplate.render(
                        template,
                        draft.projectUrl,
                        draft.publishableKey,
                        version,
                    )
                    contentResolver.openOutputStream(uri)?.use { stream ->
                        stream.write(html.toByteArray(Charsets.UTF_8))
                    } ?: error("no output stream")
                }.isSuccess
            }
            snackbar(
                if (saved) {
                    "Dashboard saved. Upload that file to Netlify Drop, then open its URL."
                } else {
                    "Could not save the dashboard file."
                },
            )
        }
    }

    private fun snackbar(message: String) {
        Snackbar.make(binding.root, message, Snackbar.LENGTH_LONG).show()
    }
}
