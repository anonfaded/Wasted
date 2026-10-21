import test from "node:test";
import assert from "node:assert/strict";
import {
  activeDevices,
  latestCommandByDevice,
  renameDevice,
  revokeDevice,
} from "../src/devices.js";

test("revoked devices are excluded from the actionable list", () => {
  const devices = activeDevices([
    { id: "a", revoked_at: null },
    { id: "b", revoked_at: "2026-10-01T00:00:00Z" },
    null,
  ]);
  assert.deepEqual(devices.map((d) => d.id), ["a"]);
});

test("latest command per device is taken from newest-first rows", () => {
  const latest = latestCommandByDevice([
    { device_id: "a", id: "cmd-2" },
    { device_id: "a", id: "cmd-1" },
    { device_id: "b", id: "cmd-3" },
  ]);

  assert.equal(latest.get("a").id, "cmd-2");
  assert.equal(latest.get("b").id, "cmd-3");
});

test("empty inputs are handled", () => {
  assert.deepEqual(activeDevices(undefined), []);
  assert.equal(latestCommandByDevice([]).size, 0);
});

test("rename sends a trimmed name through the RPC", async () => {
  const calls = [];
  const client = {
    rpc: async (name, args) => {
      calls.push({ name, args });
      return { data: { id: args.p_device_id }, error: null };
    },
  };
  await renameDevice(client, "device-1", "  Office phone  ");
  assert.deepEqual(calls, [
    { name: "rename_device", args: { p_device_id: "device-1", p_name: "Office phone" } },
  ]);
});

test("rename rejects empty and oversized names before calling Supabase", async () => {
  let called = false;
  const client = { rpc: async () => { called = true; } };
  await assert.rejects(() => renameDevice(client, "device-1", "   "), /1–80/);
  await assert.rejects(() => renameDevice(client, "device-1", "x".repeat(81)), /1–80/);
  assert.equal(called, false);
});

test("revoke calls the device RPC", async () => {
  const calls = [];
  const client = {
    rpc: async (name, args) => {
      calls.push({ name, args });
      return { error: null };
    },
  };
  await revokeDevice(client, "device-1");
  assert.deepEqual(calls, [{ name: "revoke_device", args: { p_device_id: "device-1" } }]);
});
