import { readConfig, createSupabaseClient } from "./supabase-client.js";
import { wireAuth, currentSession, onAuthChange, signOut } from "./auth.js";
import { fetchDashboardData } from "./devices.js";
import { createEnrollmentToken, tokenExpiryLabel } from "./enrollment.js";
import { saveAccountSettings } from "./settings.js";
import { createAction, setDeviceDebugMode, newIdempotencyKey, RESET_TIMER, FORCE_RESET } from "./commands.js";
import {
  extrapolatedRemaining,
  isRecentlyConnected,
  formatRemaining,
  formatLastContact,
} from "./timers.js";
import { $, toast, setBusy, confirmAction, showMessage, clearMessage } from "./ui.js";

const state = {
  client: null,
  session: null,
  handle: "",
  channel: null,
  realtimeAccountId: null,
  refreshTimeout: null,
  tokenTimer: null,
  liveTimers: [],
  data: {
    devices: [],
    statusByDevice: new Map(),
    latestCommand: new Map(),
    settings: null,
  },
};

const config = readConfig();
if (!config) {
  const banner = $("#config-error");
  banner.textContent =
    "This dashboard is not configured: add config.js (copy of config.example.js) " +
    "with your Supabase URL and publishable key.";
  banner.hidden = false;
  $("#auth-section").hidden = true;
} else {
  boot(config);
}

async function boot(cfg) {
  applyFooter(cfg);
  applyOptionalLink("#footer-privacy", cfg.privacyUrl);
  applyOptionalLink("#footer-support", cfg.supportUrl);

  state.client = createSupabaseClient(cfg);
  state.session = await currentSession(state.client);

  wireAuth(state.client);
  wireDashboard();
  wireSignOut();

  onAuthChange(state.client, (session) => {
    state.session = session;
    renderAuthState();
  });

  setInterval(tickTimers, 1000);
  setInterval(refreshDashboard, 30_000);
  window.addEventListener("online", () => {
    $("#offline-banner").hidden = true;
    refreshDashboard();
  });
  window.addEventListener("offline", () => {
    $("#offline-banner").hidden = false;
  });

  renderAuthState();
}

function applyFooter(cfg) {
  const product = cfg.productName || "Wasted Remote";
  document.title = product;
  $("#app-title").textContent = product;
  $("#footer-product").textContent = product;
  $("#footer-version").textContent = cfg.version ? `— v${cfg.version}` : "";
  $("#footer-version").hidden = !cfg.version;
}

function applyOptionalLink(selector, url) {
  const link = $(selector);
  if (!url) {
    link.hidden = true;
    return;
  }
  link.href = url;
  link.hidden = false;
}

function renderAuthState() {
  const signedIn = Boolean(state.session);
  $("#auth-section").hidden = signedIn;
  $("#dashboard").hidden = !signedIn;
  $("#sign-out").hidden = !signedIn;

  if (signedIn) {
    refreshDashboard();
  } else {
    teardownRealtime();
    state.handle = "";
    state.data = { devices: [], statusByDevice: new Map(), latestCommand: new Map(), settings: null };
  }
}

async function refreshDashboard() {
  if (!state.session) return;
  const loading = $("#loading");
  loading.hidden = false;
  try {
    if (!state.handle) {
      const { data } = await state.client.from("accounts").select("handle").maybeSingle();
      state.handle = data?.handle ?? "";
    }
    $("#account-line").textContent = state.handle
      ? `Account: ${state.handle}`
      : `Signed in as ${state.session.user.email ?? "owner"}`;

    state.data = await fetchDashboardData(state.client);
    renderSettings();
    renderDevices();
    subscribeRealtime(state.session.user.id);
    $("#offline-banner").hidden = true;
  } catch (error) {
    $("#offline-banner").hidden = false;
    toast(`Refresh failed: ${error.message}`);
  } finally {
    loading.hidden = true;
  }
}

function subscribeRealtime(accountId) {
  if (state.channel && state.realtimeAccountId === accountId) return;
  teardownRealtime();
  const filter = `account_id=eq.${accountId}`;
  state.realtimeAccountId = accountId;
  state.channel = state.client
    .channel("wasted-dashboard")
    .on("postgres_changes", { event: "*", schema: "public", table: "devices", filter }, scheduleRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "account_settings", filter }, scheduleRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "device_status", filter }, scheduleRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "device_commands", filter }, scheduleRefresh)
    .subscribe((status) => {
      if (status === "SUBSCRIBED") {
        $("#offline-banner").hidden = true;
        scheduleRefresh();
      } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
        $("#offline-banner").hidden = false;
      }
    });
}

function teardownRealtime() {
  if (!state.channel) return;
  const channel = state.channel;
  state.channel = null;
  state.realtimeAccountId = null;
  Promise.resolve(state.client.removeChannel(channel)).catch(() => {});
}

function scheduleRefresh() {
  clearTimeout(state.refreshTimeout);
  state.refreshTimeout = setTimeout(() => refreshDashboard(), 300);
}

function renderDevices() {
  const now = Date.now();
  const container = $("#devices");
  container.replaceChildren();
  state.liveTimers = [];

  const { devices, statusByDevice, latestCommand, settings } = state.data;
  $("#action-scope").textContent = devices.length
    ? `Applies to ${devices.length} active device(s).`
    : "No active devices enrolled yet.";

  if (!devices.length) {
    container.append(
      el("p", {
        className: "muted",
        text: "No devices enrolled yet. Create an enrollment token below and claim it in the app.",
      }),
    );
    return;
  }

  for (const device of devices) {
    const status = statusByDevice.get(device.id) ?? null;
    const command = latestCommand.get(device.id) ?? null;
    const fresh = isRecentlyConnected(status, now);
    const timerSpan = el("span", { text: timerText(status, now) });

    const card = el("article", { className: "device-card" }, [
      el("h3", { text: device.name || "Unnamed device" }),
      el("p", { className: "device-id", text: `ID ${device.id}` }),
      el("dl", {}, [
        el("dt", { text: "Connection" }),
        el("dd", {}, [
          el("span", {
            className: `badge ${fresh ? "fresh" : "stale"}`,
            text: fresh ? "recently connected" : "offline / stale",
          }),
        ]),
        el("dt", { text: "Last contact" }),
        el("dd", { text: formatLastContact(status) }),
        el("dt", { text: "Timer" }),
        el("dd", {}, [timerSpan]),
        el("dt", { text: "Lock timer" }),
        el("dd", { text: desiredVsActual(settings?.lock_timer_minutes, settings?.revision, status?.actual_lock_timer_minutes, "min") }),
        el("dt", { text: "USB trigger" }),
        el("dd", { text: desiredVsActual(settings?.usb_trigger_enabled, settings?.revision, status?.actual_usb_trigger_enabled, null) }),
        el("dt", { text: "Debug Mode" }),
        el("dd", {}, [
          el("span", {
            className: "badge debug",
            text: !status ? "unknown" : status.debug_mode ? "ON (wipes blocked)" : "OFF",
          }),
          el("span", { className: "inline-actions" }, [
            debugButton(device.id, true),
            debugButton(device.id, false),
          ]),
        ]),
        el("dt", { text: "Reset support" }),
        el("dd", { text: !status ? "unknown" : status.reset_supported ? "supported" : "not supported" }),
        el("dt", { text: "App / OS" }),
        el("dd", { text: status ? `${status.app_version} · Android SDK ${status.android_sdk}` : "unknown" }),
        el("dt", { text: "Last command" }),
        el("dd", { text: describeCommand(command) }),
      ]),
    ]);

    container.append(card);
    state.liveTimers.push({ el: timerSpan, status });
  }
}

function timerText(status, now) {
  if (!status) return "unknown";
  if (!status.timer_running) return "inactive";
  return `running · ${formatRemaining(extrapolatedRemaining(status, now))} left (est.)`;
}

function desiredVsActual(desired, revision, actual, unit) {
  const desiredText =
    desired === undefined || desired === null
      ? "uninitialized"
      : `${desired}${unit ? ` ${unit}` : ""} (rev ${revision ?? 0})`;
  const actualText =
    actual === undefined || actual === null
      ? "unknown"
      : `${actual}${unit ? ` ${unit}` : ""}`;
  return `${actualText} actual · ${desiredText} desired`;
}

function describeCommand(command) {
  if (!command) return "none";
  const result = command.result_code ? ` (${command.result_code})` : "";
  const when = Date.parse(command.created_at);
  const timestamp = Number.isNaN(when) ? command.created_at : new Date(when).toLocaleString();
  return `${command.command_type} — ${command.state}${result} · ${timestamp}`;
}

function renderSettings() {
  const settings = state.data.settings;
  const form = $("#settings-form");
  if (!settings) {
    $("#settings-revision").textContent = "settings unavailable";
    return;
  }
  $("#lock-minutes").value = String(settings.lock_timer_minutes);
  $("#usb-trigger").checked = Boolean(settings.usb_trigger_enabled);
  $("#settings-revision").textContent = `revision ${settings.revision}${
    settings.initialized_at ? "" : " · not initialized yet"
  }`;
  form.dataset.revision = String(settings.revision);
}

function tickTimers() {
  const now = Date.now();
  for (const entry of state.liveTimers) {
    entry.el.textContent = timerText(entry.status, now);
  }
}

function debugButton(deviceId, enable) {
  return el("button", {
    className: `small ${enable ? "" : "danger-outline"}`.trim(),
    text: enable ? "Enable" : "Disable",
    attrs: {
      type: "button",
      "data-debug-device": deviceId,
      "data-debug-enable": enable ? "true" : "false",
    },
  });
}

/** Enable and Disable both explain the effect; Disable keeps the danger styling. */
async function toggleDebugMode(deviceId, enabled, button) {
  const confirmed = await confirmAction(
    enabled
      ? {
          title: "Turn Debug Mode ON?",
          message:
            "Debug Mode blocks destructive remote commands: a Force Reset will be " +
            "logged and notified on the device instead of executing. Reset Timer and " +
            "settings sync keep working.",
          confirmLabel: "Enable",
          danger: false,
        }
      : {
          title: "Turn Debug Mode OFF?",
          message:
            "While Debug Mode is OFF, dangerous commands (including a remote Force Reset) " +
            "can wipe this device.",
          confirmLabel: "Disable",
        },
  );
  if (!confirmed) return;

  const group = button.closest(".inline-actions");
  const buttons = group ? [...group.querySelectorAll("button")] : [button];
  for (const candidate of buttons) candidate.disabled = true;

  try {
    await setDeviceDebugMode(state.client, deviceId, enabled, newIdempotencyKey());
    toast(`${enabled ? "Enable" : "Disable"} command queued for 1 device.`);
    scheduleRefresh();
  } catch (error) {
    toast(error.message);
  } finally {
    for (const candidate of buttons) candidate.disabled = false;
  }
}

function wireDashboard() {
  $("#devices").addEventListener("click", (event) => {
    const button = event.target.closest("button[data-debug-device]");
    if (!button) return;
    toggleDebugMode(
      button.dataset.debugDevice,
      button.dataset.debugEnable === "true",
      button,
    );
  });

  $("#settings-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const settings = state.data.settings;
    if (!settings) {
      showMessage("#settings-message", "Account settings are not available.");
      return;
    }
    const form = event.target;
    if (!form.reportValidity()) return;
    const button = form.querySelector("button[type=submit]");
    clearMessage("#settings-message");
    setBusy(button, true);
    try {
      const updated = await saveAccountSettings(
        state.client,
        settings.revision,
        Number($("#lock-minutes").value),
        $("#usb-trigger").checked,
      );
      state.data.settings = updated;
      toast("Settings saved — every device will apply them.");
      renderSettings();
      scheduleRefresh();
    } catch (error) {
      if (error.code === "REVISION_CONFLICT") scheduleRefresh();
      showMessage("#settings-message", error.message);
    } finally {
      setBusy(button, false);
    }
  });

  $("#reset-timer").addEventListener("click", async () => {
    const count = state.data.devices.length;
    if (!count) {
      toast("No active devices to reset.");
      return;
    }
    const confirmed = await confirmAction({
      title: "Reset Timer",
      message: `Restart the lock timer on ${count} device(s). Devices that are unlocked stay inactive.`,
    });
    if (confirmed) await sendAction(RESET_TIMER);
  });

  $("#force-reset").addEventListener("click", async () => {
    const count = state.data.devices.length;
    if (!count) {
      toast("No active devices to reset.");
      return;
    }
    const confirmed = await confirmAction({
      title: "Force Reset",
      message:
        `Send a factory-reset command to ${count} device(s). Devices in Debug Mode ` +
        "will NOT be reset. This cannot be undone.",
      typedPhrase: "RESET",
    });
    if (confirmed) await sendAction(FORCE_RESET);
  });

  $("#create-token").addEventListener("click", async () => {
    const button = $("#create-token");
    setBusy(button, true);
    try {
      const { token, expiresAt } = await createEnrollmentToken(state.client);
      $("#token-value").textContent = token;
      $("#token-output").hidden = false;
      updateTokenExpiry(expiresAt);
      clearInterval(state.tokenTimer);
      state.tokenTimer = setInterval(() => updateTokenExpiry(expiresAt), 1000);
    } catch (error) {
      toast(`Could not create a token: ${error.message}`);
    } finally {
      setBusy(button, false);
    }
  });

  $("#copy-token").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText($("#token-value").textContent);
      toast("Token copied.");
    } catch {
      toast("Copy failed — select the token manually.");
    }
  });
}

function updateTokenExpiry(expiresAt) {
  const label = tokenExpiryLabel(expiresAt);
  $("#token-expiry").textContent = label;
  if (label.startsWith("Expired")) clearInterval(state.tokenTimer);
}

async function sendAction(actionType) {
  const button = actionType === FORCE_RESET ? $("#force-reset") : $("#reset-timer");
  clearMessage("#commands-message");
  setBusy(button, true);
  try {
    const result = await createAction(state.client, actionType, newIdempotencyKey());
    toast(`Command queued for ${result.device_count} device(s).`);
    scheduleRefresh();
  } catch (error) {
    showMessage("#commands-message", error.message);
  } finally {
    setBusy(button, false);
  }
}

function wireSignOut() {
  $("#sign-out").addEventListener("click", async () => {
    await signOut(state.client);
    toast("Signed out.");
  });
}

function el(tag, { className, text, attrs } = {}, children = []) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  if (attrs) {
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  }
  for (const child of children) node.append(child);
  return node;
}
