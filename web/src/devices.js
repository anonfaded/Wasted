/** Data access + pure helpers for the device grid. */

export async function fetchDashboardData(client) {
  const [devicesResult, statusResult, commandsResult, settingsResult] = await Promise.all([
    client.from("devices")
      .select("id, account_id, name, installation_id, enrolled_at, revoked_at")
      .order("created_at", { ascending: true }),
    client.from("device_status").select("*"),
    client.from("device_commands")
      .select("id, device_id, command_type, state, result_code, created_at")
      .order("created_at", { ascending: false })
      .limit(200),
    client.from("account_settings").select("*").maybeSingle(),
  ]);

  for (const result of [devicesResult, statusResult, commandsResult]) {
    if (result.error) throw new Error(result.error.message);
  }

  const devices = activeDevices(devicesResult.data ?? []);
  const statusByDevice = new Map((statusResult.data ?? []).map((s) => [s.device_id, s]));
  const latestCommand = latestCommandByDevice(commandsResult.data ?? []);

  return { devices, statusByDevice, latestCommand, settings: settingsResult.data ?? null };
}

/** Non-revoked devices only; revoked history is preserved server-side but not actionable. */
export function activeDevices(rows) {
  return (rows ?? []).filter((row) => row && !row.revoked_at);
}

/** Rows must arrive newest-first; keeps the first (latest) command per device. */
export function latestCommandByDevice(rows) {
  const latest = new Map();
  for (const row of rows ?? []) {
    if (!latest.has(row.device_id)) latest.set(row.device_id, row);
  }
  return latest;
}

export async function renameDevice(client, deviceId, name) {
  const trimmed = String(name ?? "").trim();
  if (trimmed.length < 1 || trimmed.length > 80) {
    throw new Error("Device name must be 1–80 characters.");
  }
  const { data, error } = await client.rpc("rename_device", {
    p_device_id: deviceId,
    p_name: trimmed,
  });
  if (error) throw new Error(error.message);
  return data;
}

export async function revokeDevice(client, deviceId) {
  const { error } = await client.rpc("revoke_device", { p_device_id: deviceId });
  if (error) throw new Error(error.message);
}
