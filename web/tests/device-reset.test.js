import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
const main = await readFile(new URL("../src/main.js", import.meta.url), "utf8");

test("Devices tab exposes a fleet-wide Force Reset entry point", () => {
  assert.match(html, /id="fleet-actions"/);
  assert.match(html, /id="fleet-force-reset"/);
  // Must be a styled destructive button, not a plain secondary one.
  const button = html.match(/<button id="fleet-force-reset"[^>]*class="danger"|<button[^>]*class="danger"[^>]*id="fleet-force-reset"/);
  assert.ok(button, "fleet reset button must use the danger style");
  // Hidden until devices load so it never shows a dead control.
  assert.match(html, /<div id="fleet-actions" class="fleet-actions" hidden>/);
});

test("every device card renders a per-device Reset action", () => {
  assert.match(main, /"data-device-force-reset": device\.id/);
  assert.match(main, /button\[data-device-force-reset\]/);
});

test("both new entry points reuse the existing force_reset command", () => {
  // No new RPC: the fleet button goes through sendCommand, not a bespoke action.
  const fleetHandler = main.slice(main.indexOf('$("#fleet-force-reset").addEventListener'));
  assert.match(fleetHandler.slice(0, 600), /sendCommand\(FORCE_RESET/);
  assert.match(fleetHandler.slice(0, 600), /scope: "all"/);
  const cardHandler = main.slice(main.indexOf("async function resetSingleDevicePrompt"));
  assert.match(cardHandler.slice(0, 500), /sendCommand\(FORCE_RESET/);
  assert.match(cardHandler.slice(0, 500), /scope: "selected"/);
});

test("the typed confirmation is shared, not duplicated", () => {
  const confirmations = main.match(/typedPhrase: "RESET"/g) ?? [];
  assert.equal(confirmations.length, 1, "only one Force Reset confirmation may exist");
  assert.match(main, /function confirmForceReset\(targets\)/);
});

test("Devices tab reset is disabled while offline", () => {
  assert.match(main, /const fleetReset = \$\("#fleet-force-reset"\)/);
  assert.match(main, /fleetReset\.disabled = !online/);
  assert.match(main, /\[data-device-force-reset\]/);
});

test("fleet actions stay hidden unless the preference is on and devices exist", () => {
  assert.match(main, /fleet\.hidden = !state\.fleetBannerEnabled \|\| !state\.data\.devices\.length/);
  assert.match(main, /if \(fleet\) fleet\.hidden = !visible \|\| !state\.fleetBannerEnabled/);
  assert.match(main, /applyFleetBannerVisibility\(\)/);
});

test("the banner preference ships enabled and is stored per browser", () => {
  assert.match(main, /FLEET_BANNER_KEY = "wasted_dashboard_fleet_banner"/);
  assert.match(main, /fleetBannerEnabled: loadStoredBoolDefaultOn\(FLEET_BANNER_KEY\)/);
  assert.match(main, /saveStoredBool\(FLEET_BANNER_KEY, state\.fleetBannerEnabled\)/);
  // A missing key must read as ON, unlike loadStoredBool which defaults to false.
  assert.match(main, /return value === null \? true : value === "true"/);
  // The switch starts checked so the default is visible before localStorage is read.
  assert.match(html, /id="fleet-reset-banner-toggle" type="checkbox" checked/);
});

test("disabling the banner keeps Force Reset reachable from Controls", () => {
  // The banner is a display preference only: no command path may depend on it.
  const sendCommand = main.slice(main.indexOf("async function sendCommand"));
  assert.ok(
    !sendCommand.slice(0, 900).includes("fleetBannerEnabled"),
    "the command path must not be gated on a display preference",
  );
  assert.match(main, /Force Reset is still available under Controls/);
});
