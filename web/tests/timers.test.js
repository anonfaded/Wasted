import test from "node:test";
import assert from "node:assert/strict";
import {
  FRESHNESS_WINDOW_MS,
  formatRemaining,
  extrapolatedRemaining,
  isRecentlyConnected,
  formatLastContact,
} from "../src/timers.js";

test("formatRemaining renders HH:MM:SS and day prefixes", () => {
  assert.equal(formatRemaining(0), "00:00:00");
  assert.equal(formatRemaining(3661), "01:01:01");
  assert.equal(formatRemaining(90000), "1d 01:00:00");
  assert.equal(formatRemaining(-5), "00:00:00");
});

test("extrapolatedRemaining subtracts elapsed time and clamps at zero", () => {
  const now = Date.parse("2026-10-20T12:00:00Z");
  const sampledAt = new Date(now - 10_000).toISOString();

  assert.equal(
    extrapolatedRemaining(
      { timer_running: true, timer_sampled_at: sampledAt, timer_remaining_seconds: 100 },
      now,
    ),
    90,
  );
  assert.equal(
    extrapolatedRemaining(
      { timer_running: true, timer_sampled_at: sampledAt, timer_remaining_seconds: 5 },
      now,
    ),
    0,
  );
  assert.equal(
    extrapolatedRemaining({ timer_running: false, timer_remaining_seconds: 100 }, now),
    0,
  );
});

test("freshness window is exactly 150 seconds", () => {
  assert.equal(FRESHNESS_WINDOW_MS, 150_000);
  const now = Date.parse("2026-10-20T12:00:00Z");

  const fresh = { last_seen_at: new Date(now - 149_000).toISOString() };
  const stale = { last_seen_at: new Date(now - 151_000).toISOString() };

  assert.equal(isRecentlyConnected(fresh, now), true);
  assert.equal(isRecentlyConnected(stale, now), false);
  assert.equal(isRecentlyConnected(null, now), false);
  assert.equal(
    isRecentlyConnected({ last_seen_at: new Date(now).toISOString() }, now),
    true,
  );
});

test("last contact is never hidden", () => {
  assert.equal(formatLastContact(null), "never");
  assert.equal(
    formatLastContact({ last_seen_at: "not-a-date" }),
    "not-a-date",
  );
});
