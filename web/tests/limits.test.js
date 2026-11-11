import assert from "node:assert/strict";
import test from "node:test";
import {
  LIMIT_DEFAULTS,
  commandExpirySummary,
  formatLimitMinutes,
  formatLimitSeconds,
  limitsFromSettings,
  presenceWindowLabel,
  presenceWindowMs,
} from "../src/limits.js";

const settings = {
  ...LIMIT_DEFAULTS,
  limits_revision: 3,
};

test("limits are read directly from the current settings row", () => {
  assert.deepEqual(limitsFromSettings(settings), LIMIT_DEFAULTS);
  assert.deepEqual(
    limitsFromSettings({ ...settings, presence_window_seconds: 90 }),
    { ...LIMIT_DEFAULTS, presence_window_seconds: 90 },
  );
});

test("active window helpers use the configured value", () => {
  assert.equal(presenceWindowMs(settings), 150_000);
  assert.equal(presenceWindowLabel(settings), "150 seconds");
  assert.equal(presenceWindowMs({ ...settings, presence_window_seconds: 90 }), 90_000);
});

test("minute formatting omits zero units", () => {
  assert.equal(formatLimitMinutes(5), "5 minutes");
  assert.equal(formatLimitMinutes(60), "1 hour");
  assert.equal(formatLimitMinutes(90), "1 hour 30 minutes");
  assert.equal(formatLimitMinutes(1440), "1 day");
  assert.equal(formatLimitMinutes(10080), "7 days");
});

test("second formatting omits zero units", () => {
  assert.equal(formatLimitSeconds(150), "2 minutes 30 seconds");
  assert.equal(formatLimitSeconds(30), "30 seconds");
  assert.equal(formatLimitSeconds(60), "1 minute");
  assert.equal(formatLimitSeconds(0), "0 seconds");
});

test("command expiry summary reflects saved values", () => {
  assert.match(commandExpirySummary(settings), /Reset Timer 1 day/);
  assert.match(commandExpirySummary(settings), /Force Reset 10 minutes/);
  assert.match(commandExpirySummary(settings), /Lock Devices 5 minutes/);
});
