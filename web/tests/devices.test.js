import test from "node:test";
import assert from "node:assert/strict";
import { activeDevices, latestCommandByDevice } from "../src/devices.js";

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
