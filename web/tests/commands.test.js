import test from "node:test";
import assert from "node:assert/strict";
import {
  createAction,
  newIdempotencyKey,
  setDeviceDebugMode,
  RESET_TIMER,
  FORCE_RESET,
  DEBUG_MODE_ON,
  DEBUG_MODE_OFF,
} from "../src/commands.js";

test("idempotency keys are UUID v4 strings", () => {
  const key = newIdempotencyKey();
  assert.match(
    key,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
  );
  assert.notEqual(newIdempotencyKey(), key, "every submission needs a fresh key");
});

test("action types match the server allowlist", () => {
  assert.equal(RESET_TIMER, "reset_timer");
  assert.equal(FORCE_RESET, "force_reset");
  assert.equal(DEBUG_MODE_ON, "debug_mode_on");
  assert.equal(DEBUG_MODE_OFF, "debug_mode_off");
});

test("createAction forwards type and key and returns the server summary", async () => {
  let captured = null;
  const client = {
    rpc: async (name, params) => {
      captured = { name, params };
      return { data: { action_id: "a1", device_count: 2 }, error: null };
    },
  };
  const key = newIdempotencyKey();

  const result = await createAction(client, FORCE_RESET, key);

  assert.equal(captured.name, "create_account_action");
  assert.deepEqual(captured.params, {
    p_action_type: FORCE_RESET,
    p_idempotency_key: key,
  });
  assert.equal(result.device_count, 2);
});

test("server errors are surfaced as thrown messages", async () => {
  const client = {
    rpc: async () => ({ data: null, error: { message: "unsupported action type" } }),
  };
  await assert.rejects(() => createAction(client, "nope", newIdempotencyKey()), /unsupported action type/);
});

test("setDeviceDebugMode forwards the per-device request", async () => {
  let captured = null;
  const client = {
    rpc: async (name, params) => {
      captured = { name, params };
      return { data: { action_id: "a1", device_count: 1 }, error: null };
    },
  };
  const key = newIdempotencyKey();

  const result = await setDeviceDebugMode(client, "device-1", false, key);

  assert.equal(captured.name, "set_device_debug_mode");
  assert.deepEqual(captured.params, {
    p_device_id: "device-1",
    p_debug_mode: false,
    p_idempotency_key: key,
  });
  assert.equal(result.device_count, 1);
});

test("setDeviceDebugMode surfaces server errors", async () => {
  const client = {
    rpc: async () => ({ data: null, error: { message: "device not found" } }),
  };
  await assert.rejects(
    () => setDeviceDebugMode(client, "gone", true, newIdempotencyKey()),
    /device not found/,
  );
});
