package me.lucky.wasted.remote.domain

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteWireModelsTest {

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Test
    fun `reconcile response decodes the RPC wire shape`() {
        val raw = """
            {
              "server_time": "2026-10-18T16:00:00Z",
              "device": {"id": "d1", "account_id": "a1", "name": "Phone", "installation_id": "i1", "enrolled_at": "2026-10-18T15:00:00Z"},
              "settings": {"revision": 2, "lock_timer_minutes": 1440, "usb_trigger_enabled": true, "initialized": true},
              "commands": [
                {"id": "c1", "action_id": "x1", "command_type": "reset_timer", "state": "queued", "created_at": "2026-10-18T15:59:00Z", "expires_at": "2026-10-19T15:59:00Z"},
                {"id": "c2", "action_id": "x2", "command_type": "force_reset", "state": "debug_blocked", "created_at": "2026-10-18T15:58:00Z", "expires_at": "2026-10-18T16:08:00Z"}
              ]
            }
        """.trimIndent()

        val response = json.decodeFromString(RemoteReconcileResponse.serializer(), raw)

        assertEquals("d1", response.device.id)
        assertEquals("a1", response.device.accountId)
        assertEquals(2L, response.settings.revision)
        assertEquals(1440, response.settings.lockTimerMinutes)
        assertTrue(response.settings.usbTriggerEnabled)
        assertEquals(2, response.commands.size)
        assertEquals(RemoteCommandType.RESET_TIMER, response.commands[0].commandType)
        assertEquals(RemoteCommandState.QUEUED, response.commands[0].state)
        assertEquals(RemoteCommandType.FORCE_RESET, response.commands[1].commandType)
        assertEquals(RemoteCommandState.DEBUG_BLOCKED, response.commands[1].state)
    }

    @Test
    fun `reconcile response tolerates unknown server fields`() {
        val raw = """
            {"server_time": "t",
             "device": {"id": "d1", "account_id": "a1", "installation_id": "i1", "name": "N", "enrolled_at": "e", "created_at": "c", "updated_at": "u"},
             "settings": {"revision": 0, "lock_timer_minutes": 1, "usb_trigger_enabled": false, "initialized": false},
             "commands": [],
             "future_field": true}
        """.trimIndent()

        val response = json.decodeFromString(RemoteReconcileResponse.serializer(), raw)

        assertTrue(response.commands.isEmpty())
        assertEquals("i1", response.device.installationId)
    }

    @Test
    fun `claim params serialize with p prefixed names`() {
        val params = ClaimEnrollmentParams(
            token = "tok",
            installationId = "inst",
            deviceName = "Name",
            lockTimerMinutes = 1440,
            usbTriggerEnabled = true,
        )
        val encoded = json.encodeToString(ClaimEnrollmentParams.serializer(), params)

        assertTrue(encoded.contains("\"p_token\":\"tok\""))
        assertTrue(encoded.contains("\"p_installation_id\":\"inst\""))
        assertTrue(encoded.contains("\"p_local_lock_timer_minutes\":1440"))
        assertTrue(encoded.contains("\"p_local_usb_trigger_enabled\":true"))
    }

    @Test
    fun `transition params serialize state enums as wire strings`() {
        val params = TransitionCommandParams(
            deviceId = "d1",
            commandId = "c1",
            expectedState = RemoteCommandState.QUEUED,
            newState = RemoteCommandState.RECEIVED,
        )
        val encoded = json.encodeToString(TransitionCommandParams.serializer(), params)

        assertTrue(encoded.contains("\"p_expected_state\":\"queued\""))
        assertTrue(encoded.contains("\"p_new_state\":\"received\""))
    }

    @Test
    fun `command states map every wire value`() {
        val pairs = listOf(
            "queued" to RemoteCommandState.QUEUED,
            "received" to RemoteCommandState.RECEIVED,
            "executing" to RemoteCommandState.EXECUTING,
            "applied" to RemoteCommandState.APPLIED,
            "reset_initiated" to RemoteCommandState.RESET_INITIATED,
            "debug_blocked" to RemoteCommandState.DEBUG_BLOCKED,
            "rejected" to RemoteCommandState.REJECTED,
            "failed" to RemoteCommandState.FAILED,
            "expired" to RemoteCommandState.EXPIRED,
        )
        for ((wire, expected) in pairs) {
            assertEquals(
                expected,
                json.decodeFromString(RemoteCommandState.serializer(), "\"$wire\""),
            )
        }
    }
}
