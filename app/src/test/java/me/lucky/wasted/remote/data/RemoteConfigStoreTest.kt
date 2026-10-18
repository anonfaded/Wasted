package me.lucky.wasted.remote.data

import me.lucky.wasted.remote.domain.RemoteConfig
import me.lucky.wasted.testing.InMemorySharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteConfigStoreTest {
    private val validConfig = RemoteConfig(
        projectUrl = "https://abcdefgh.supabase.co",
        publishableKey = "sb_publishable_abc123",
        websiteUrl = "https://wasted.example.com",
    )

    private fun store() = RemoteConfigStore(InMemorySharedPreferences())

    @Test
    fun `fresh store defaults to unconfigured and off`() {
        val store = store()
        assertFalse(store.isConfigured)
        assertFalse(store.remoteEnabled)
        assertNull(store.load())
        assertFalse(store.canStartRemoteWork())
    }

    @Test
    fun `save then load round trips with trimming`() {
        val store = store()
        assertTrue(store.save(validConfig.copy(projectUrl = " ${validConfig.projectUrl} ")))
        assertEquals(validConfig, store.load())
        assertTrue(store.isConfigured)
    }

    @Test
    fun `invalid config is not stored`() {
        val store = store()
        assertFalse(store.save(validConfig.copy(publishableKey = "sb_secret_nope")))
        assertNull(store.load())
        assertFalse(store.isConfigured)
    }

    @Test
    fun `http config rejected`() {
        val store = store()
        assertFalse(store.save(validConfig.copy(projectUrl = "http://127.0.0.1:54321")))
        assertNull(store.load())
    }

    @Test
    fun `remote work requires enabled and valid config`() {
        val store = store()
        assertTrue(store.save(validConfig))
        assertFalse(store.canStartRemoteWork())
        store.remoteEnabled = true
        assertTrue(store.canStartRemoteWork())
    }

    @Test
    fun `partial stored config fails closed`() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString("project_url", validConfig.projectUrl)
            .putString("publishable_key", validConfig.publishableKey)
            .commit()
        val store = RemoteConfigStore(prefs)
        assertNull(store.load())
        assertFalse(store.isConfigured)
    }

    @Test
    fun `corrupt stored config fails closed`() {
        val prefs = InMemorySharedPreferences()
        prefs.edit()
            .putString("project_url", "not a url")
            .putString("publishable_key", "junk")
            .putString("website_url", "junk")
            .putBoolean("remote_enabled", true)
            .commit()
        val store = RemoteConfigStore(prefs)
        assertNull(store.load())
        assertFalse(store.canStartRemoteWork())
    }

    @Test
    fun `clear configuration resets to fail-closed defaults`() {
        val store = store()
        assertTrue(store.save(validConfig))
        store.remoteEnabled = true
        store.clearConfiguration()
        assertNull(store.load())
        assertFalse(store.remoteEnabled)
        assertFalse(store.isConfigured)
        assertFalse(store.canStartRemoteWork())
    }
}
