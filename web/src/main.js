import { readConfig, createSupabaseClient } from "./supabase-client.js";
import { wireAuth, currentSession, onAuthChange, signOut } from "./auth.js";
import { fetchDashboardData, renameDevice, revokeDevice } from "./devices.js";
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
  applySetupLinks(cfg);
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

function applySetupLinks(cfg) {
  const ref = projectRef(cfg.supabaseUrl);
  const base = ref
    ? `https://supabase.com/dashboard/project/${ref}`
    : "https://supabase.com/dashboard";
  const project = $("#setup-project-link");
  if (project) project.href = base;
  const sql = $("#setup-sql-link");
  if (sql) sql.href = `${base}/sql/new`;
  const auth = $("#setup-auth-link");
  if (auth) auth.href = `${base}/auth/providers`;
  const url = $("#setup-url-link");
  if (url) url.href = `${base}/auth/url-configuration`;
}

function projectRef(value) {
  try {
    const host = new URL(value).hostname;
    if (!host.endsWith(".supabase.co")) return null;
    const ref = host.slice(0, -".supabase.co".length);
    if (!/^[a-z0-9-]+$/.test(ref) || /^YOUR-/.test(ref)) return null;
    return ref;
  } catch {
    return null;
  }
}

function applyOptionalLink(selector, url) {
  const link = $(selector);
  let parsed = null;
  try {
    parsed = url ? new URL(url) : null;
  } catch {
    parsed = null;
  }
  if (!parsed || parsed.protocol !== "https:") {
    link.hidden = true;
    link.removeAttribute("href");
    return;
  }
  link.href = parsed.href;
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
    clearEnrollmentToken();
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
    $("#account-setup").hidden = Boolean(state.handle);
    if (!state.handle && !$("#setup-handle").value) {
      try {
        $("#setup-handle").value = localStorage.getItem("wasted_pending_handle") || "";
      } catch {
        // Storage is optional.
      }
    }

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
      el("div", { className: "empty-state" }, [
        el("p", { text: "No devices enrolled yet." }),
        el("p", {
          className: "hint",
          text:
            "Enable Remote Management in the app, create an enrollment token below, " +
            "and claim it in the app. The device appears here after its first sync.",
        }),
      ]),
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
      el("div", { className: "device-actions" }, [
        el("button", {
          className: "small",
          text: "Rename",
          attrs: {
            type: "button",
            "data-device-rename": device.id,
            "data-device-name": device.name || "",
            title: "Rename this device in the dashboard only",
          },
        }),
        el("button", {
          className: "small danger-outline",
          text: "Revoke",
          attrs: {
            type: "button",
            "data-device-revoke": device.id,
            title: "Stop remote commands for this device without wiping it",
          },
        }),
      ]),
      ...(status
        ? []
        : [
            el("p", {
              className: "hint",
              text: "Waiting for this device's first sync.",
            }),
          ]),
      el("dl", {}, [
        el("dt", { text: "Connection" }),
        el("dd", {}, [
          el("span", {
            className: `badge ${fresh ? "fresh" : "stale"}`,
            text: fresh ? "recently connected" : "offline / stale",
            attrs: {
              title: fresh
                ? "Contacted the server within the last 150 seconds."
                : "No contact in the last 150 seconds. The exact time is shown below.",
            },
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
            attrs: {
              title: !status
                ? "Reported by the device after its first sync."
                : status.debug_mode
                  ? "ON blocks Force Reset; Reset Timer and settings sync still work."
                  : "OFF allows destructive remote commands such as Force Reset.",
            },
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

const COMMAND_LABELS = {
  reset_timer: "Reset Timer",
  force_reset: "Force Reset",
  debug_mode_on: "Debug Mode ON",
  debug_mode_off: "Debug Mode OFF",
};

const STATE_LABELS = {
  queued: "queued",
  received: "received",
  executing: "executing",
  applied: "applied",
  reset_initiated: "reset initiated — no completion signal after a wipe",
  debug_blocked: "blocked by Debug Mode",
  rejected: "rejected",
  failed: "failed",
  expired: "expired",
};

function describeCommand(command) {
  if (!command) return "none";
  const label = COMMAND_LABELS[command.command_type] ?? command.command_type;
  const state = STATE_LABELS[command.state] ?? command.state;
  const result = command.result_code ? ` (${command.result_code})` : "";
  const when = Date.parse(command.created_at);
  const timestamp = Number.isNaN(when) ? command.created_at : new Date(when).toLocaleString();
  return `${label} — ${state}${result} · ${timestamp}`;
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
      title: enable
        ? "Turn Debug Mode ON for this device (blocks destructive commands)"
        : "Turn Debug Mode OFF for this device (destructive commands can execute)",
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

/** Rename is dashboard-only; it does not change the device identity or its credentials. */
function openRenameDialog(deviceId, currentName, button) {
  const dialog = $("#rename-dialog");
  const input = $("#rename-device-name");
  input.value = currentName;
  dialog.returnValue = "";
  dialog.showModal();
  const onClose = async () => {
    dialog.removeEventListener("close", onClose);
    if (dialog.returnValue !== "ok") return;
    const name = input.value.trim();
    if (!name || name.length > 80) {
      toast("Device name must be 1–80 characters.");
      return;
    }
    setBusy(button, true, "Renaming…");
    try {
      await renameDevice(state.client, deviceId, name);
      toast("Device renamed.");
      scheduleRefresh();
    } catch (error) {
      toast(error.message);
    } finally {
      setBusy(button, false);
    }
  };
  dialog.addEventListener("close", onClose);
}

async function revokeDevicePrompt(deviceId, button) {
  const confirmed = await confirmAction({
    title: "Revoke this device?",
    message:
      "Remote commands stop immediately. The device keeps working normally and is not wiped. " +
      "To use it again, open Remote Management in the app, tap Reset enrollment, then claim a " +
      "new token.",
    confirmLabel: "Revoke device",
  });
  if (!confirmed) return;
  setBusy(button, true, "Revoking…");
  try {
    await revokeDevice(state.client, deviceId);
    toast("Device revoked.");
    scheduleRefresh();
  } catch (error) {
    toast(error.message);
  } finally {
    setBusy(button, false);
  }
}

function wireDashboard() {
  $("#account-setup-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.target;
    if (!form.reportValidity()) return;
    const handle = $("#setup-handle").value.trim();
    const button = form.querySelector("button[type=submit]");
    clearMessage("#account-setup-message");
    setBusy(button, true);
    try {
      const { error } = await state.client.rpc("initialize_owner_account", { p_handle: handle });
      if (error) throw new Error(error.message);
      state.handle = handle;
      try {
        localStorage.removeItem("wasted_pending_handle");
      } catch {
        // Storage is optional.
      }
      $("#account-setup").hidden = true;
      toast("Account setup complete.");
      refreshDashboard();
    } catch (error) {
      showMessage("#account-setup-message", error.message);
    } finally {
      setBusy(button, false);
    }
  });

  $("#devices").addEventListener("click", (event) => {
    const debug = event.target.closest("button[data-debug-device]");
    if (debug) {
      toggleDebugMode(
        debug.dataset.debugDevice,
        debug.dataset.debugEnable === "true",
        debug,
      );
      return;
    }
    const rename = event.target.closest("button[data-device-rename]");
    if (rename) {
      openRenameDialog(rename.dataset.deviceRename, rename.dataset.deviceName, rename);
      return;
    }
    const revoke = event.target.closest("button[data-device-revoke]");
    if (revoke) {
      revokeDevicePrompt(revoke.dataset.deviceRevoke, revoke);
    }
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
    const lockMinutes = Number($("#lock-minutes").value);
    const usbEnabled = $("#usb-trigger").checked;
    const confirmed = await confirmAction({
      title: "Save settings?",
      message:
        `Lock timer: ${lockMinutes} minute(s). USB trigger: ` +
        `${usbEnabled ? "enabled" : "disabled"}. This creates a new revision and every enrolled ` +
        "device applies it at its next sync.",
      confirmLabel: "Save and sync",
      danger: false,
    });
    if (!confirmed) return;
    const button = form.querySelector("button[type=submit]");
    clearMessage("#settings-message");
    setBusy(button, true);
    try {
      const updated = await saveAccountSettings(
        state.client,
        settings.revision,
        lockMinutes,
        usbEnabled,
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
    const confirmed = await confirmAction({
      title: "Create enrollment token?",
      message:
        "This creates a single-use code valid for 10 minutes. Anyone with the code can add a " +
        "device to this account, so share it only with your own device.",
      confirmLabel: "Create token",
      danger: false,
    });
    if (!confirmed) return;
    const button = $("#create-token");
    setBusy(button, true);
    try {
      const { token, expiresAt } = await createEnrollmentToken(state.client);
      clearEnrollmentToken();
      $("#token-value").textContent = token;
      $("#token-output").hidden = false;
      updateTokenExpiry(expiresAt);
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

function clearEnrollmentToken() {
  clearInterval(state.tokenTimer);
  state.tokenTimer = null;
  const value = $("#token-value");
  if (value) value.textContent = "";
  const output = $("#token-output");
  if (output) output.hidden = true;
  const expiry = $("#token-expiry");
  if (expiry) expiry.textContent = "";
}

function updateTokenExpiry(expiresAt) {
  const label = tokenExpiryLabel(expiresAt);
  $("#token-expiry").textContent = label;
  if (label.startsWith("Expired")) {
    clearEnrollmentToken();
    toast("Enrollment token expired — create a new one.");
  }
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
    clearEnrollmentToken();
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
