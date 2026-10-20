import test from "node:test";
import assert from "node:assert/strict";
import { saveAccountSettings } from "../src/settings.js";

test("saveAccountSettings forwards the revision and values", async () => {
  let captured = null;
  const client = {
    rpc: async (name, params) => {
      captured = { name, params };
      return { data: { revision: 3, lock_timer_minutes: 60, usb_trigger_enabled: true }, error: null };
    },
  };

  const result = await saveAccountSettings(client, 2, 60, true);

  assert.equal(captured.name, "update_account_settings");
  assert.deepEqual(captured.params, {
    p_expected_revision: 2,
    p_lock_timer_minutes: 60,
    p_usb_trigger_enabled: true,
  });
  assert.equal(result.revision, 3);
});

test("stale revisions map to a REVISION_CONFLICT error", async () => {
  const client = {
    rpc: async () => ({ data: null, error: { message: "settings revision conflict" } }),
  };

  await assert.rejects(
    () => saveAccountSettings(client, 1, 60, true),
    (error) => error.code === "REVISION_CONFLICT" && /changed elsewhere/i.test(error.message),
  );
});

test("other server errors surface their message", async () => {
  const client = {
    rpc: async () => ({ data: null, error: { message: "lock timer minutes must be between 1 and 525600" } }),
  };

  await assert.rejects(
    () => saveAccountSettings(client, 1, 0, true),
    /between 1 and 525600/,
  );
});
