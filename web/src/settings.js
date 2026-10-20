/** Revision-protected account settings update. */
export async function saveAccountSettings(client, expectedRevision, lockTimerMinutes, usbTriggerEnabled) {
  const { data, error } = await client.rpc("update_account_settings", {
    p_expected_revision: expectedRevision,
    p_lock_timer_minutes: lockTimerMinutes,
    p_usb_trigger_enabled: usbTriggerEnabled,
  });

  if (error) {
    if (/revision conflict/i.test(error.message || "")) {
      const conflict = new Error("Settings changed elsewhere — refreshed. Review and save again.");
      conflict.code = "REVISION_CONFLICT";
      throw conflict;
    }
    throw new Error(error.message);
  }
  return data;
}
