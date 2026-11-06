import { readConfig, createSupabaseClient } from "./supabase-client.js";
import { wireAuth, currentSession, onAuthChange, signOut } from "./auth.js";
import {
  ensureOwnerAccount,
  updateOwnerHandle,
  validateHandle,
} from "./account.js";
import { fetchDashboardData, renameDevice, revokeDevice } from "./devices.js";
import { createEnrollmentToken, tokenExpiryLabel } from "./enrollment.js";
import { saveAccountSettings, saveDeviceSettings } from "./settings.js";
import { createAction, setDeviceDebugMode, newIdempotencyKey, RESET_TIMER, FORCE_RESET, LOCK_NOW } from "./commands.js";
import { batteryLabel, batteryPercent, batteryTone, isLowBattery } from "./battery.js";
import {
  extrapolatedRemaining,
  isRecentlyConnected,
  formatRemaining,
  formatLastContact,
  formatDateTime,
  formatMinutes,
} from "./timers.js";
import { $, toast, setBusy, confirmAction, showMessage, clearMessage, copyText } from "./ui.js";
import { actionUnavailableMessage, isReachabilityError, retryDelayMs } from "./connection.js";
import { installRipple } from "./ripple.js";

const state = {
  client: null,
  session: null,
  handle: "",
  handleLoaded: false,
  online: navigator.onLine !== false,
  connectionReason: null,
  dataLoaded: false,
  cacheSavedAt: 0,
  channel: null,
  realtimeAccountId: null,
  refreshTimeout: null,
  retryTimer: null,
  refreshFailures: 0,
  refreshInFlight: false,
  explicitSignOut: false,
  connection: { projectUrl: "", publishableKey: "", dashboardUrl: "" },
  lastDeviceCount: null,
  tokenTimer: null,
  liveTimers: [],
  targetScope: "selected",
  selectedDeviceIds: new Set(),
  data: {
    devices: [],
    statusByDevice: new Map(),
    latestCommand: new Map(),
    effectiveSettingsByDevice: new Map(),
    settings: null,
  },
};

const CACHE_PREFIX = "wasted_dashboard_cache_v2_";

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
  applyConnectionInfo(cfg);
  applySetupLinks(cfg);
  applyOptionalLink("#footer-privacy", cfg.privacyUrl);
  applyOptionalLink("#footer-support", cfg.supportUrl);

  state.client = createSupabaseClient(cfg);
  wireInstallPrompt();
  state.session = await currentSession(state.client);

  wireAuth(state.client);
  wireDashboard();
  wireDashboardTabs();
  wireSignOut();
  wireHeaderMenu();
  installRipple();
  onAuthChange(state.client, (session, event) => {
    if (event === "SIGNED_OUT" && state.session && !state.explicitSignOut) {
      toast("Session ended — sign in again.", "info");
    }
    state.session = session;
    renderAuthState();
  });

  setInterval(tickTimers, 1000);
  setInterval(() => {
    if (!document.hidden) refreshDashboard();
  }, 60_000);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) refreshDashboard();
  });
  let offlineTimer;
  window.addEventListener("online", () => {
    clearTimeout(offlineTimer);
    clearTimeout(state.retryTimer);
    state.retryTimer = null;
    state.refreshFailures = 0;
    setDashboardOnline(true);
    refreshDashboard();
  });
  window.addEventListener("offline", () => {
    clearTimeout(offlineTimer);
    clearTimeout(state.retryTimer);
    state.retryTimer = null;
    offlineTimer = setTimeout(() => {
      loadCachedDashboard();
      setDashboardOnline(false, "offline");
      renderSettings();
      renderDevices();
    }, 400);
  });

  renderAuthState();
}

function applyConnectionInfo(cfg) {
  const projectUrl = String(cfg.supabaseUrl ?? "").trim();
  const publishableKey = String(cfg.supabasePublishableKey ?? "").trim();
  const section = $("#menu-connection");
  if (!section || !projectUrl || !publishableKey) return;

  const localPreview = ["localhost", "127.0.0.1", "::1"].includes(location.hostname);
  let dashboardUrl = "";
  if (!localPreview) {
    const current = new URL(location.href);
    current.hash = "";
    current.search = "";
    dashboardUrl = current.origin + current.pathname;
  }
  if (!dashboardUrl) dashboardUrl = String(cfg.dashboardUrl ?? "").trim();

  state.connection = { projectUrl, publishableKey, dashboardUrl };
  $("#menu-project-url").textContent = projectUrl;
  $("#menu-publishable-key").textContent = publishableKey;
  const dashboardField = $("#menu-dashboard-url-field");
  if (dashboardField) {
    $("#menu-dashboard-url").textContent = dashboardUrl;
    dashboardField.hidden = !dashboardUrl;
  }
  section.hidden = false;
  $("#menu-divider").hidden = false;

  const fields = [
    ["#copy-project-url", "projectUrl", "Project URL"],
    ["#copy-publishable-key", "publishableKey", "Publishable key"],
    ["#copy-dashboard-url", "dashboardUrl", "Dashboard URL"],
  ];
  for (const [selector, key, label] of fields) {
    $(selector)?.addEventListener("click", async () => {
      try {
        await copyText(state.connection[key]);
        toast(`${label} copied.`, "success");
      } catch (_) {
        toast(`Could not copy ${label.toLowerCase()}.`, "error");
      }
    });
  }
}

function applyFooter(cfg) {
  const product = cfg.productName || "Wasted Remote";
  document.title = product;
  const title = $("#app-title .brand-title");
  if (title) title.textContent = product;
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
  const hooks = $("#setup-hooks-link");
  if (hooks) hooks.href = `${base}/auth/hooks`;
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
    state.handleLoaded = false;
    state.dataLoaded = false;
    state.cacheSavedAt = 0;
    state.refreshFailures = 0;
    state.lastDeviceCount = null;
    state.data = {
      devices: [],
      statusByDevice: new Map(),
      latestCommand: new Map(),
      effectiveSettingsByDevice: new Map(),
      settings: null,
    };
    state.selectedDeviceIds.clear();
    $("#account-panel").hidden = true;
    $("#account-email").textContent = "—";
    $("#account-message").textContent = "";
  }
  if (!signedIn) closeHeaderMenu();
  syncHeaderMenu();
  setDashboardOnline(navigator.onLine !== false);
}

async function refreshDashboard() {
  if (!state.session || state.refreshInFlight) return;
  state.refreshInFlight = true;
  const loading = $("#loading");
  loading.hidden = false;

  try {
    if (!navigator.onLine) {
      loadCachedDashboard();
      setDashboardOnline(false, "offline");
      renderSettings();
      renderDevices();
      return;
    }

    try {
      if (!state.handleLoaded) {
        state.handle = await ensureOwnerAccount(state.client, state.session);
        state.handleLoaded = true;
      }
      $("#account-line").textContent = state.handle
        ? `Account: ${state.handle}`
        : `Signed in as ${state.session.user.email ?? "owner"}`;
      $("#account-email").textContent = state.session.user.email ?? "Not available";
      $("#account-panel").hidden = !state.handle;
      if (state.handle && document.activeElement !== $("#account-handle")) {
        $("#account-handle").value = state.handle;
      }

      state.data = await fetchDashboardData(state.client);
      state.dataLoaded = true;
      state.refreshFailures = 0;
      clearTimeout(state.retryTimer);
      state.retryTimer = null;
      if (
        state.lastDeviceCount !== null &&
        state.data.devices.length > state.lastDeviceCount &&
        !$("#token-output").hidden
      ) {
        clearEnrollmentToken();
        toast("Device enrolled. Waiting for its first sync.", "success");
      }
      state.lastDeviceCount = state.data.devices.length;
      saveDashboardCache();
      setDashboardOnline(true);
      renderSettings();
      renderDevices();
      subscribeRealtime(state.session.user.id);
      $("#offline-banner").hidden = true;
    } catch (error) {
      if (error.code === "OWNER_EXISTS" || error.code === "MISSING_PROFILE") {
        await signOut(state.client);
        showMessage("#auth-message", error.message, "error");
        return;
      }
      loadCachedDashboard();
      state.refreshFailures += 1;

      if (!navigator.onLine) {
        setDashboardOnline(false, "offline");
        renderSettings();
        renderDevices();
        return;
      }

      if (isReachabilityError(error)) {
        if (state.refreshFailures >= 2 || !state.dataLoaded) {
          setDashboardOnline(false, "unreachable");
          renderSettings();
          renderDevices();
          toast("Could not reach Supabase. Showing cached data; retrying.", "error");
        } else {
          toast("Could not refresh from Supabase. Retrying.", "error");
        }
        scheduleDashboardRetry();
      } else {
        toast(`Refresh failed: ${error.message}`, "error");
      }
    }
  } finally {
    state.refreshInFlight = false;
    loading.hidden = true;
  }
}

function scheduleDashboardRetry() {
  if (state.retryTimer) return;
  state.retryTimer = setTimeout(() => {
    state.retryTimer = null;
    if (!document.hidden) refreshDashboard();
  }, retryDelayMs(state.refreshFailures));
}

function dashboardCacheKey() {
  return state.session?.user?.id ? `${CACHE_PREFIX}${state.session.user.id}` : "";
}

function saveDashboardCache() {
  if (!state.dataLoaded || !state.session) return;
  const key = dashboardCacheKey();
  if (!key) return;
  try {
    state.cacheSavedAt = Date.now();
    localStorage.setItem(
      key,
      JSON.stringify({
        savedAt: state.cacheSavedAt,
        devices: state.data.devices,
        statusByDevice: [...state.data.statusByDevice.entries()],
        latestCommand: [...state.data.latestCommand.entries()],
        effectiveSettingsByDevice: [...state.data.effectiveSettingsByDevice.entries()],
        settings: state.data.settings,
      }),
    );
  } catch {
    // Cache is best effort; the in-memory dashboard still works.
  }
}

function loadCachedDashboard() {
  if (state.dataLoaded) return true;
  const key = dashboardCacheKey();
  if (!key) return false;
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return false;
    const cached = JSON.parse(raw);
    if (!Array.isArray(cached.devices)) return false;
    state.data = {
      devices: cached.devices,
      statusByDevice: new Map(cached.statusByDevice ?? []),
      latestCommand: new Map(cached.latestCommand ?? []),
      effectiveSettingsByDevice: new Map(cached.effectiveSettingsByDevice ?? []),
      settings: cached.settings ?? null,
    };
    state.dataLoaded = true;
    state.cacheSavedAt = Number(cached.savedAt) || 0;
    return true;
  } catch {
    return false;
  }
}

function clearDashboardCache() {
  const key = dashboardCacheKey();
  if (!key) return;
  try {
    localStorage.removeItem(key);
  } catch {
    // Cache is optional.
  }
}

function requireOnline(selector) {
  if (state.online) return true;
  showMessage(selector, actionUnavailableMessage(state.connectionReason), "error");
  return false;
}

function setDashboardOnline(online, reason = state.connectionReason ?? "offline") {
  state.online = online;
  state.connectionReason = online ? null : reason;

  const banner = $("#offline-banner");
  const offline = reason === "offline";
  if (banner) {
    banner.classList.toggle("warning", !online && !offline);
    banner.classList.toggle("error", online || offline);
  }
  if (!state.session) {
    if (banner) {
      banner.textContent = offline
        ? "Offline — sign-in, account creation, and dashboard access require a connection. Reconnect and try again."
        : "Can't reach Supabase — sign-in and account creation are unavailable. Retrying automatically.";
      banner.hidden = online;
    }
    for (const selector of ["#sign-in", "#create-account"]) {
      const button = $(selector);
      if (button) button.disabled = !online;
    }
    return;
  }

  if (banner) {
    if (online) {
      banner.hidden = true;
    } else {
      const detail = state.dataLoaded
        ? state.cacheSavedAt
          ? ` Showing cached data last updated ${new Date(state.cacheSavedAt).toLocaleTimeString()}.`
          : " Showing the data already loaded in this session."
        : " No cached dashboard data is available.";
      banner.textContent = offline
        ? "Offline —" +
          detail +
          " Commands, settings saves, enrollment, and refresh are disabled until the connection returns."
        : "Can't reach Supabase —" +
          detail +
          " Commands, settings saves, enrollment, and refresh are disabled until Supabase responds. Retrying automatically.";
      banner.hidden = false;
    }
  }

  const selectors = [
    "#create-token",
    "#settings-form button[type=submit]",
    "#account-form button[type=submit]",
    "#target-all",
    "#target-selected",
  ];
  for (const selector of selectors) {
    const button = $(selector);
    if (button) button.disabled = !online;
  }
  document
    .querySelectorAll(
      "[data-device-rename], [data-device-revoke], [data-device-settings], [data-device-select], [data-debug-device]",
    )
    .forEach((button) => {
      button.disabled = !online || button.dataset.debugUnknown === "true";
    });
  if ($("#action-scope")) renderCommandScope(state.data.devices);
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
    .on("postgres_changes", { event: "*", schema: "public", table: "device_settings", filter }, scheduleRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "device_status", filter }, scheduleRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "device_commands", filter }, scheduleRefresh)
    .subscribe((status) => {
      if (status === "SUBSCRIBED") {
        if (state.online) $("#offline-banner").hidden = true;
        scheduleRefresh();
      } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
        // Realtime is only an invalidation channel; HTTP commands still work.
        scheduleRefresh();
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
  if (document.hidden) return;
  clearTimeout(state.refreshTimeout);
  state.refreshTimeout = setTimeout(() => refreshDashboard(), 300);
}

function renderDevices() {
  const now = Date.now();
  const container = $("#devices");
  container.replaceChildren();
  state.liveTimers = [];

  const { devices, statusByDevice, latestCommand, effectiveSettingsByDevice } = state.data;
  pruneSelectedDevices(devices);
  renderDeviceSummary(devices, statusByDevice, now);
  const unavailableWithoutCache = !state.online && !state.dataLoaded;
  const unavailablePrefix =
    state.connectionReason === "offline" ? "Offline" : "Can't reach Supabase";

  if (!devices.length) {
    container.append(
      el("div", { className: "empty-state" }, [
        el("p", {
          text: unavailableWithoutCache
            ? `${unavailablePrefix} — no cached dashboard data is available.`
            : "No devices enrolled yet.",
        }),
        el("p", {
          className: "hint",
          text: unavailableWithoutCache
            ? state.connectionReason === "offline"
              ? "Reconnect to load your devices. Commands and settings saves are disabled while offline."
              : "Supabase is unreachable, so cached data cannot be refreshed. Commands and settings saves are disabled until it responds."
            : "Enable Remote Management in the app, create an enrollment token below, " +
              "and claim it in the app. The device appears here after its first sync.",
        }),
      ]),
    );
    setDashboardOnline(state.online);
    return;
  }

  for (const device of devices) {
    const status = statusByDevice.get(device.id) ?? null;
    const effective = effectiveSettingsByDevice.get(device.id) ?? null;
    const command = latestCommand.get(device.id) ?? null;
    const fresh = isRecentlyConnected(status, now);
    const timerSpan = el("span", {
      className: status?.timer_running ? "timer-live" : "timer-inactive",
      text: timerText(status, now),
    });
    const lastContactEl = el("dd", { text: formatLastContact(status, now) });
    const selectInput = el("input", {
      attrs: {
        type: "checkbox",
        "data-device-select": device.id,
        "aria-label": `Select ${device.name || "this device"} for commands`,
      },
    });
    selectInput.checked = state.selectedDeviceIds.has(device.id);

    const card = el("article", { className: "device-card" }, [
      el("div", { className: "device-card-head" }, [
        el("h3", { text: device.name || "Unnamed device" }),
        batteryPill(status, status?.battery_percent == null
          ? "The phone has not reported a battery level yet."
          : `Battery reported by the phone${status.battery_charging ? " · charging" : ""}.`),
      ]),
      el("p", { className: "device-id", text: `ID ${device.id}` }),
      el("div", { className: "device-actions" }, [
        el("label", { className: "device-select" }, [
          selectInput,
          el("span", { text: "Select" }),
        ]),
        el("button", {
          className: "small",
          text: "Settings",
          icon: "controls",
          attrs: {
            type: "button",
            "data-device-settings": device.id,
            title: "Set this device's remote settings or inherit the global values",
          },
        }),
        el("button", {
          className: "small",
          text: "Rename",
          icon: "pencil",
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
          icon: "trash",
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
        fieldTerm(
          "Connection",
          "Active means a status update arrived within the last 150 seconds; the device normally reports about once a minute. Inactive means no contact in that window. Colour key: 🟢 Active · 🔴 Inactive.",
        ),
        el("dd", {}, [
          statusBadge(fresh ? "Active" : "Inactive", fresh ? "active" : "inactive", fresh
            ? "Contacted the server within the last 150 seconds."
            : "No contact in the last 150 seconds. The exact time is shown below."),
        ]),
        fieldTerm(
          "Last contact",
          "The last successful status sync. It normally updates about once a minute, and immediately after a command is applied.",
        ),
        lastContactEl,
        fieldTerm(
          "Battery",
          "Battery level and charging state reported with the last status sync. Unknown is not the same as 0%. Colour key: 🟢 healthy · 🟡 21–50% · 🔴 20% or less · ⚪ unknown.",
        ),
        el("dd", {}, [
          batteryPill(status, status?.battery_percent == null
            ? "No battery level reported yet."
            : "Reported at the last status sync; not a live millisecond feed."),
        ]),
        fieldTerm(
          "Settings status",
          "Current means the phone has applied the latest global and per-device override revisions. Pending means it has not synced them yet. Colour key: 🟢 Current · 🟡 Pending.",
        ),
        el("dd", {}, [settingsStatusNode(status, effective)]),
        fieldTerm(
          "Live countdown",
          "Actual time remaining before the Lock trigger fires. It starts after the phone locks or the screen turns off, is cancelled when unlocked, and stays inactive while the Lock trigger is OFF on the phone.",
        ),
        el("dd", {}, [timerSpan]),
        fieldTerm(
          "Lock trigger",
          "The ON/OFF switch that arms the Lock workflow. It is not a timer and shows no remaining time. The saved setting is this device's override, otherwise the global value. Colour key: 🟢 ON · 🔴 OFF.",
        ),
        el("dd", {}, [
          desiredVsActualNode(effective?.lock_trigger_enabled, status?.actual_lock_trigger_enabled, formatEnabled),
        ]),
        fieldTerm(
          "Lock delay setting",
          "The effective wait before the Lock trigger fires — global default or this device's override, not time remaining. The phone reports it in whole minutes. It runs only while the trigger is ON.",
        ),
        el("dd", {}, [
          desiredVsActualNode(effective?.lock_timer_minutes, status?.actual_lock_timer_minutes, formatMinutes),
        ]),
        fieldTerm(
          "USB trigger",
          "When ON, connecting USB data to a locked device can fire the USB trigger. The effective value is the global default unless this device has an override. Colour key: 🟢 ON · 🔴 OFF.",
        ),
        el("dd", {}, [
          desiredVsActualNode(effective?.usb_trigger_enabled, status?.actual_usb_trigger_enabled, formatEnabled),
        ]),
        fieldTerm(
          "Debug Mode",
          "ON blocks Force Reset; Reset Timer and settings sync still work. The switch sends a command to this device and asks for confirmation. Colour key: 🟢 ON (safe) · 🔴 OFF (destructive commands allowed).",
        ),
        el("dd", {}, [
          statusBadge(
            !status ? "Unknown" : status.debug_mode ? "ON · wipes blocked" : "OFF",
            !status ? "unknown" : status.debug_mode ? "on" : "off",
            !status
              ? "Reported by the device after its first sync."
              : status.debug_mode
                ? "ON blocks Force Reset; Reset Timer and settings sync still work."
                : "OFF allows destructive remote commands such as Force Reset.",
          ),
          el("span", { className: "inline-actions" }, [debugSwitch(device, status)]),
        ]),
        fieldTerm(
          "Reset support",
          "Whether the device can run a reset with its current Device Admin/Device Owner protections. Android 14+ installs that are not Device Owner may use a best-effort wipe. Colour key: 🟢 Supported · 🔴 Not supported.",
        ),
        el("dd", {}, [
          !status
            ? statusBadge("Unknown", "unknown")
            : status.reset_supported
              ? statusBadge("Supported", "supported")
              : statusBadge("Not supported", "danger"),
        ]),
        fieldTerm(
          "App / OS",
          "The app version and Android SDK reported by the device.",
        ),
        el("dd", { text: status ? `${status.app_version} · Android SDK ${status.android_sdk}` : "unknown" }),
        fieldTerm(
          "Last command",
          "The newest remote command and its current state. The timestamp is when it was queued.",
        ),
        el("dd", {}, [describeCommandNode(command)]),
      ]),
      el("p", {
        className: "card-note",
        text: "Settings show the saved setting (global default plus any device override). Device reports is the last value from the phone. The Live countdown is actual time left; it is inactive while unlocked or while the Lock trigger is OFF.",
      }),
    ]);

    container.append(card);
    state.liveTimers.push({ el: timerSpan, status, lastContactEl });
  }
  setDashboardOnline(state.online);
  renderCommandScope(devices);
}

function renderDeviceSummary(devices, statusByDevice, now) {
  const container = $("#device-summary");
  if (!container) return;
  if (!state.dataLoaded && !state.online) {
    container.replaceChildren();
    return;
  }
  const active = devices.filter((device) =>
    isRecentlyConnected(statusByDevice.get(device.id), now),
  ).length;
  const debug = devices.filter((device) => statusByDevice.get(device.id)?.debug_mode).length;
  const lowBattery = devices.filter((device) => isLowBattery(statusByDevice.get(device.id))).length;
  container.replaceChildren(
    summaryCard("Devices", devices.length, "enrolled"),
    summaryCard("Active", active, "within 150 s", active ? "success" : "muted"),
    summaryCard("Debug Mode", debug, "wipes blocked", debug ? "success" : "muted"),
    summaryCard("Low battery", lowBattery, "20% or less", lowBattery ? "danger" : "muted"),
  );
}

function pruneSelectedDevices(devices) {
  const active = new Set(devices.map((device) => device.id));
  for (const id of [...state.selectedDeviceIds]) {
    if (!active.has(id)) state.selectedDeviceIds.delete(id);
  }
}

function targetDevices() {
  if (state.targetScope === "all") return state.data.devices;
  return state.data.devices.filter((device) => state.selectedDeviceIds.has(device.id));
}

function commandTargets() {
  return {
    scope: state.targetScope,
    deviceIds: state.targetScope === "all" ? [] : [...state.selectedDeviceIds],
  };
}

function renderCommandScope(devices) {
  const selected = devices.filter((device) => state.selectedDeviceIds.has(device.id));
  const scope = $("#action-scope");
  if (scope) {
    scope.textContent = state.targetScope === "all"
      ? `Applies to all ${devices.length} enrolled device(s); inactive devices receive it on reconnect.`
      : selected.length
        ? `Applies to ${selected.length} selected device(s): ${selected
            .map((device) => device.name || "Unnamed device")
            .join(", ")}.`
        : "Select one or more devices on the cards below, or choose All enrolled devices.";
  }
  const summary = $("#target-summary");
  if (summary) summary.textContent = `${selected.length} selected`;
  const canTarget = state.online && devices.length > 0 &&
    (state.targetScope === "all" || selected.length > 0);
  for (const selector of ["#lock-devices", "#reset-timer", "#force-reset"]) {
    const button = $(selector);
    if (button) button.disabled = !canTarget;
  }
  const all = $("#target-all");
  const selectedRadio = $("#target-selected");
  if (all) all.checked = state.targetScope === "all";
  if (selectedRadio) selectedRadio.checked = state.targetScope === "selected";
}

function settingsStatusNode(status, effective) {
  if (!status || !effective) {
    return el("span", { className: "status-line" }, [
      statusBadge("Unknown", "unknown"),
      el("span", { className: "muted", text: "until the first sync" }),
    ]);
  }
  const current =
    Number(status.applied_global_settings_revision) >= Number(effective.global_revision) &&
    Number(status.applied_device_settings_revision) >= Number(effective.device_revision);
  const appliedAt = status.settings_applied_at
    ? ` · applied ${formatDateTime(Date.parse(status.settings_applied_at))}`
    : "";
  return el("span", { className: "status-line" }, [
    statusBadge(current ? "Current" : "Pending", current ? "current" : "pending"),
    el("span", {
      className: "muted",
      text: `global v${effective.global_revision}, device v${effective.device_revision}${appliedAt}`,
    }),
  ]);
}

function statusBadge(text, tone = "unknown", title = "") {
  return el("span", {
    className: `status-badge ${tone}`,
    text,
    ...(title ? { attrs: { title } } : {}),
  });
}

function batteryPill(status, title) {
  const percent = batteryPercent(status);
  const gauge = el("span", {
    className: "battery-gauge",
    attrs: { "aria-hidden": "true" },
  }, percent === null
    ? []
    : [el("span", { className: "battery-fill", attrs: { style: `width:${percent}%` } })]);
  return el("span", {
    className: `battery-pill ${batteryTone(status)}`,
    attrs: title ? { title } : {},
  }, [gauge, el("span", { text: batteryLabel(status) })]);
}

function booleanNode(value) {
  if (value === true) return el("span", { className: "value-on", text: "ON" });
  if (value === false) return el("span", { className: "value-off", text: "OFF" });
  return el("span", { className: "value-unknown", text: "Unknown" });
}

function desiredVsActualNode(desired, actual, formatValue) {
  const desiredText =
    desired === undefined || desired === null ? "not set" : formatValue(desired);
  const actualText =
    actual === undefined || actual === null ? "unknown" : formatValue(actual);
  const actualNode = typeof actual === "boolean"
    ? booleanNode(actual)
    : el("span", { text: actualText });
  if (actualText === desiredText) {
    return el("span", { className: "status-line" }, [
      el("span", { text: "Device reports: " }),
      actualNode,
      el("span", { className: "muted", text: " · saved setting matches" }),
    ]);
  }
  return el("span", { className: "status-line" }, [
    el("span", { text: "Device reports: " }),
    actualNode,
    el("span", { className: "muted", text: " · saved setting: " }),
    el("span", { text: desiredText }),
  ]);
}

function summaryCard(label, value, detail, tone = "") {
  return el("div", { className: "stat" }, [
    el("span", { className: `stat-value ${tone}`.trim(), text: String(value) }),
    el("span", { className: "stat-label", text: label }),
    el("span", { className: "stat-detail", text: detail }),
  ]);
}

function timerText(status, now) {
  if (!status) return "unknown";
  if (status.actual_lock_trigger_enabled === false) return "inactive — Lock trigger is OFF";
  if (!status.timer_running) return "inactive — no active lock countdown";
  return `live · ${formatRemaining(extrapolatedRemaining(status, now))} left (estimated)`;
}

function formatEnabled(value) {
  return value ? "ON" : "OFF";
}

const COMMAND_LABELS = {
  reset_timer: "Reset Timer",
  force_reset: "Force Reset",
  lock_now: "Lock Devices",
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

function fieldTerm(label, info) {
  return el("dt", {}, [
    el("span", { text: label }),
    el("button", {
      className: "info-button",
      attrs: {
        type: "button",
        "data-info": info,
        "aria-label": `About ${label}`,
        title: info,
      },
    }, [el("span", { text: "?" })]),
  ]);
}

function describeCommandNode(command) {
  if (!command) return el("span", { className: "muted", text: "none" });
  const label = COMMAND_LABELS[command.command_type] ?? command.command_type;
  const state = STATE_LABELS[command.state] ?? command.state;
  const result = command.result_code ? ` (${command.result_code})` : "";
  const when = Date.parse(command.created_at);
  const timestamp = Number.isNaN(when) ? command.created_at : formatDateTime(when);
  const tone = command.state === "applied"
    ? "success"
    : ["failed", "expired", "rejected"].includes(command.state)
      ? "danger"
      : command.state === "debug_blocked"
        ? "warning"
        : "pending";
  return el("span", { className: "status-line" }, [
    el("span", { text: `${label} — ` }),
    statusBadge(state, tone),
    el("span", { className: "muted", text: `${result} · ${timestamp}` }),
  ]);
}

function renderSettings() {
  const settings = state.data.settings;
  const form = $("#settings-form");
  if (!settings) {
    $("#settings-revision").textContent = state.online
      ? "settings unavailable"
      : state.connectionReason === "offline"
        ? "offline — reconnect to load settings"
        : "Supabase unreachable — retrying";
    return;
  }
  $("#lock-trigger").checked = Boolean(settings.lock_trigger_enabled);
  $("#lock-minutes").value = String(settings.lock_timer_minutes);
  $("#usb-trigger").checked = Boolean(settings.usb_trigger_enabled);
  $("#lock-human").textContent =
    `Configured value: ${formatMinutes(settings.lock_timer_minutes)}`;
  const revision = $("#settings-revision");
  revision.textContent = `Global settings version ${settings.revision}${
    settings.initialized_at ? "" : " · not initialized yet"
  }`;
  revision.title =
    "The global version increases each time global settings are saved. Devices with overrides still apply the newest global values for fields they inherit.";
  form.dataset.revision = String(settings.revision);
}

function tickTimers() {
  const now = Date.now();
  for (const entry of state.liveTimers) {
    entry.el.textContent = timerText(entry.status, now);
    if (entry.lastContactEl) {
      entry.lastContactEl.textContent = formatLastContact(entry.status, now);
    }
  }
}

function debugSwitch(device, status) {
  const input = el("input", {
    attrs: {
      type: "checkbox",
      "data-debug-device": device.id,
      "aria-label": `Debug Mode for ${device.name || "this device"}`,
      ...(status ? {} : { "data-debug-unknown": "true" }),
    },
  });
  input.checked = Boolean(status?.debug_mode);
  input.disabled = !status;
  return el("label", {
    className: "switch",
    attrs: {
      title: status
        ? "ON blocks Force Reset; OFF allows destructive remote commands."
        : "The current value appears after the device's first sync.",
    },
  }, [
    input,
    el("span", { className: "switch-track", attrs: { "aria-hidden": "true" } }, [
      el("span", { className: "switch-thumb" }),
    ]),
  ]);
}

/** The switch sends one per-device command; cancelling restores the previous position. */
async function toggleDebugMode(deviceId, enabled, input) {
  if (!state.online) {
    input.checked = !enabled;
    toast(actionUnavailableMessage(state.connectionReason), "error");
    return;
  }
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
  if (!confirmed) {
    input.checked = !enabled;
    return;
  }

  input.disabled = true;
  try {
    await setDeviceDebugMode(state.client, deviceId, enabled, newIdempotencyKey());
    toast(`${enabled ? "Enable" : "Disable"} command queued for 1 device.`);
    scheduleRefresh();
  } catch (error) {
    input.checked = !enabled;
    toast(error.message, "error");
  } finally {
    input.disabled = false;
  }
}

function openDeviceSettingsDialog(deviceId) {
  if (!state.online) {
    toast(actionUnavailableMessage(state.connectionReason), "error");
    return;
  }
  const effective = state.data.effectiveSettingsByDevice.get(deviceId);
  const device = state.data.devices.find((item) => item.id === deviceId);
  if (!effective || !device) {
    toast("Device settings are not loaded yet.", "error");
    return;
  }
  const dialog = $("#device-settings-dialog");
  $("#device-settings-device-id").value = deviceId;
  $("#device-settings-revision").value = String(effective.device_revision);
  $("#device-settings-name").textContent = device.name || "Unnamed device";
  $("#device-settings-message").textContent = "";

  setOverrideField("ds-lock-trigger", "ds-lock-trigger-inherit", effective.lock_trigger_overridden);
  setOverrideField("ds-usb-trigger", "ds-usb-trigger-inherit", effective.usb_trigger_overridden);
  setOverrideField("ds-lock-minutes", "ds-lock-minutes-inherit", effective.lock_timer_overridden);
  $("#ds-lock-trigger").checked = Boolean(effective.lock_trigger_enabled);
  $("#ds-usb-trigger").checked = Boolean(effective.usb_trigger_enabled);
  $("#ds-lock-minutes").value = String(effective.lock_timer_minutes);
  const globalSettings = state.data.settings;
  $("#ds-lock-minutes-global").textContent = globalSettings
    ? `Global: ${formatMinutes(globalSettings.lock_timer_minutes)}`
    : "Global value unavailable.";

  dialog.returnValue = "";
  dialog.showModal();
  const onClose = async () => {
    dialog.removeEventListener("close", onClose);
    if (dialog.returnValue !== "ok") return;
    const revision = Number($("#device-settings-revision").value);
    const inheritMinutes = $("#ds-lock-minutes-inherit").checked;
    const minutes = Number($("#ds-lock-minutes").value);
    if (!inheritMinutes && (!Number.isInteger(minutes) || minutes < 1 || minutes > 525600)) {
      toast("Lock delay must be between 1 and 525600 minutes.", "error");
      return;
    }
    const patch = {
      lock_trigger_enabled: $("#ds-lock-trigger-inherit").checked
        ? null
        : $("#ds-lock-trigger").checked,
      lock_timer_minutes: inheritMinutes ? null : minutes,
      usb_trigger_enabled: $("#ds-usb-trigger-inherit").checked
        ? null
        : $("#ds-usb-trigger").checked,
    };
    const confirmed = await confirmAction({
      title: "Save device settings?",
      message:
        `Target: ${device.name || "Unnamed device"}.\n` +
        `Lock trigger: ${patch.lock_trigger_enabled === null ? "inherit global" : patch.lock_trigger_enabled ? "ON" : "OFF"}.\n` +
        `Lock delay: ${patch.lock_timer_minutes === null ? "inherit global" : formatMinutes(minutes)}.\n` +
        `USB trigger: ${patch.usb_trigger_enabled === null ? "inherit global" : patch.usb_trigger_enabled ? "ON" : "OFF"}.\n\n` +
        "This creates a new device settings version; no other device is affected.",
      confirmLabel: "Save device settings",
      danger: false,
    });
    if (!confirmed) return;
    try {
      await saveDeviceSettings(state.client, deviceId, revision, patch);
      toast("Device settings saved.", "success");
      scheduleRefresh();
    } catch (error) {
      if (error.code === "REVISION_CONFLICT") scheduleRefresh();
      toast(error.message, "error");
    }
  };
  dialog.addEventListener("close", onClose);
}

function setOverrideField(valueId, inheritId, overridden) {
  const inherit = $(`#${inheritId}`);
  const value = $(`#${valueId}`);
  inherit.checked = !overridden;
  value.disabled = !overridden;
}

function wireDeviceSettingsFields() {
  for (const [valueId, inheritId, fallbackId] of [
    ["ds-lock-trigger", "ds-lock-trigger-inherit", null],
    ["ds-lock-minutes", "ds-lock-minutes-inherit", "ds-lock-minutes-global"],
    ["ds-usb-trigger", "ds-usb-trigger-inherit", null],
  ]) {
    const inherit = $(`#${inheritId}`);
    inherit?.addEventListener("change", () => {
      const value = $(`#${valueId}`);
      value.disabled = inherit.checked;
      if (fallbackId && inherit.checked) {
        $("#" + fallbackId).textContent = "Using the global value.";
      }
    });
  }
}

/** Rename is dashboard-only; it does not change the device identity or its credentials. */
function openRenameDialog(deviceId, currentName, button) {
  if (!state.online) {
    toast(actionUnavailableMessage(state.connectionReason), "error");
    return;
  }
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
      toast("Device name must be 1–80 characters.", "error");
      return;
    }
    setBusy(button, true, "Renaming…");
    try {
      await renameDevice(state.client, deviceId, name);
      toast("Device renamed.", "success");
      scheduleRefresh();
    } catch (error) {
      toast(error.message, "error");
    } finally {
      setBusy(button, false);
    }
  };
  dialog.addEventListener("close", onClose);
}

async function revokeDevicePrompt(deviceId, button) {
  if (!state.online) {
    toast(actionUnavailableMessage(state.connectionReason), "error");
    return;
  }
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
    toast("Device revoked.", "success");
    scheduleRefresh();
  } catch (error) {
    toast(error.message, "error");
  } finally {
    setBusy(button, false);
  }
}

function wireDashboardTabs() {
  const tabs = [...document.querySelectorAll("[data-dashboard-tab]")];
  const panels = [...document.querySelectorAll("[data-dashboard-panel]")];
  if (!tabs.length || !panels.length) return;

  const select = (name, focus = false) => {
    for (const tab of tabs) {
      const active = tab.dataset.dashboardTab === name;
      tab.setAttribute("aria-selected", String(active));
      tab.tabIndex = active ? 0 : -1;
      if (active && focus) tab.focus();
    }
    for (const panel of panels) {
      panel.hidden = panel.dataset.dashboardPanel !== name;
    }
  };

  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => select(tab.dataset.dashboardTab));
    tab.addEventListener("keydown", (event) => {
      let next = null;
      if (event.key === "ArrowRight" || event.key === "ArrowDown") {
        next = tabs[(index + 1) % tabs.length];
      } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
        next = tabs[(index - 1 + tabs.length) % tabs.length];
      } else if (event.key === "Home") {
        next = tabs[0];
      } else if (event.key === "End") {
        next = tabs[tabs.length - 1];
      }
      if (!next) return;
      event.preventDefault();
      select(next.dataset.dashboardTab, true);
    });
  });

  select("devices");
}

function wireInstallPrompt() {
  const button = $("#install-app");
  if (!button) return;
  const dialog = $("#install-dialog");
  const message = $("#install-message");

  const standalone =
    window.matchMedia("(display-mode: standalone)").matches ||
    window.navigator.standalone === true;
  if (standalone) {
    button.hidden = true;
    syncHeaderMenu();
    return;
  }

  let deferredPrompt = null;
  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault();
    deferredPrompt = event;
  });

  button.addEventListener("click", async () => {
    if (deferredPrompt) {
      deferredPrompt.prompt();
      await deferredPrompt.userChoice.catch(() => undefined);
      deferredPrompt = null;
      button.hidden = true;
      syncHeaderMenu();
      return;
    }
    if (message && dialog) {
      message.textContent = installHelp();
      dialog.showModal();
    }
  });

  window.addEventListener("appinstalled", () => {
    deferredPrompt = null;
    button.hidden = true;
    syncHeaderMenu();
  });
}

function installHelp() {
  const ua = navigator.userAgent;
  const isFirefox = /Firefox|FxiOS/i.test(ua);
  const isSafari = /Safari/i.test(ua) && !/Chrome|Chromium|Edg|OPR/i.test(ua);
  const isLocal = ["localhost", "127.0.0.1", "::1"].includes(location.hostname);

  if (isLocal) {
    return "This is the local preview. Open the deployed HTTPS dashboard, then use the browser's install option. Firefox desktop cannot install web apps natively.";
  }
  if (isFirefox) {
    return "Firefox desktop does not install manifest-based web apps natively. Use Chrome or Edge, or install the “PWAs for Firefox” extension. On Firefox Android, use the browser menu → Add to Home screen (a browser shortcut, not a standalone app).";
  }
  if (isSafari) {
    return "On iPhone or iPad, tap Share → Add to Home Screen. On macOS Safari, choose File → Add to Dock.";
  }
  return "Use the install icon in the browser address bar or the browser menu → Install app. If no option appears, the page must be served over HTTPS.";
}

function wireDashboard() {
  $("#lock-minutes").addEventListener("input", (event) => {
    const minutes = Number(event.target.value);
    $("#lock-human").textContent = Number.isFinite(minutes) && minutes > 0
      ? `Configured value: ${formatMinutes(minutes)}`
      : "";
  });
  $("#settings-info").addEventListener("click", () => {
    toast(
      "These are global defaults for Lock trigger, lock delay, and USB trigger. Each device can override any field from its Settings button; an override wins until cleared with Inherit global. Global saves do not clear device overrides. A local phone change is reported separately and does not rewrite either target.",
      "info",
    );
  });

  $("#account-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!requireOnline("#account-message")) return;
    const handle = $("#account-handle").value.trim();
    const validation = validateHandle(handle);
    if (validation) {
      showMessage("#account-message", validation, "error");
      $("#account-handle").focus();
      return;
    }
    if (handle === state.handle) {
      showMessage("#account-message", "That is already your account name.", "info");
      return;
    }
    const confirmed = await confirmAction({
      title: "Change account name?",
      message:
        `Change the account name to “${handle}”? This updates every browser signed into this account.`,
      confirmLabel: "Save name",
      danger: false,
    });
    if (!confirmed) return;

    const button = event.target.querySelector("button[type=submit]");
    clearMessage("#account-message");
    setBusy(button, true);
    try {
      const account = await updateOwnerHandle(state.client, handle);
      state.handle = account?.handle ?? handle;
      $("#account-handle").value = state.handle;
      $("#account-line").textContent = `Account: ${state.handle}`;
      toast("Account name updated.", "success");
    } catch (error) {
      showMessage("#account-message", error.message, "error");
    } finally {
      setBusy(button, false);
    }
  });

  for (const radio of document.querySelectorAll('input[name="command-target"]')) {
    radio.addEventListener("change", () => {
      if (!radio.checked) return;
      state.targetScope = radio.value === "all" ? "all" : "selected";
      renderCommandScope(state.data.devices);
    });
  }
  wireDeviceSettingsFields();

  $("#devices").addEventListener("change", (event) => {
    const select = event.target.closest("input[data-device-select]");
    if (select) {
      if (select.checked) state.selectedDeviceIds.add(select.dataset.deviceSelect);
      else state.selectedDeviceIds.delete(select.dataset.deviceSelect);
      renderCommandScope(state.data.devices);
      return;
    }
    const debug = event.target.closest("input[data-debug-device]");
    if (!debug) return;
    toggleDebugMode(debug.dataset.debugDevice, debug.checked, debug);
  });

  $("#devices").addEventListener("click", (event) => {
    const info = event.target.closest("button[data-info]");
    if (info) {
      toast(info.dataset.info, "info");
      return;
    }
    const settingsButton = event.target.closest("button[data-device-settings]");
    if (settingsButton) {
      openDeviceSettingsDialog(settingsButton.dataset.deviceSettings);
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
    if (!requireOnline("#settings-message")) return;
    const settings = state.data.settings;
    if (!settings) {
      showMessage("#settings-message", "Account settings are not available.", "error");
      return;
    }
    const form = event.target;
    if (!form.reportValidity()) return;
    const lockTrigger = $("#lock-trigger").checked;
    const lockMinutes = Number($("#lock-minutes").value);
    const usbEnabled = $("#usb-trigger").checked;
    const confirmed = await confirmAction({
      title: "Save trigger settings?",
      message:
        `Lock trigger: ${lockTrigger ? "ON" : "OFF"}. ` +
        `Lock delay: ${formatMinutes(lockMinutes)}. ` +
        `USB trigger: ${usbEnabled ? "enabled" : "disabled"}. ` +
        "This creates a new global settings version. Every device that inherits a field applies its new value at the next sync; device overrides remain in place.",
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
        lockTrigger,
      );
      state.data.settings = updated;
      toast("Global settings saved — inheriting devices will apply them.", "success");
      renderSettings();
      scheduleRefresh();
    } catch (error) {
      if (error.code === "REVISION_CONFLICT") scheduleRefresh();
      showMessage("#settings-message", error.message, "error");
    } finally {
      setBusy(button, false);
    }
  });

  $("#lock-devices").addEventListener("click", async () => {
    const targets = targetDevices();
    if (!targets.length) {
      toast("Select at least one device first.");
      return;
    }
    const names = targets.map((device) => device.name || "Unnamed device").join(", ");
    const first = await confirmAction({
      title: "Lock devices?",
      message:
        `This locks the screen on ${targets.length} device(s) at their next sync:\n${names}\n\n` +
        "It does not wipe data or change settings. You will be asked once more.",
      confirmLabel: "Continue",
      danger: false,
    });
    if (!first) return;
    const second = await confirmAction({
      title: "Confirm lock",
      message:
        `Send the lock command to ${targets.length} device(s) now? The devices stay locked until ` +
        "someone unlocks them locally.",
      confirmLabel: "Lock now",
      danger: false,
    });
    if (second) await sendAction(LOCK_NOW);
  });

  $("#reset-timer").addEventListener("click", async () => {
    const targets = targetDevices();
    if (!targets.length) {
      toast("Select at least one device first.");
      return;
    }
    const now = Date.now();
    const activeTimers = targets
      .map((device) => {
        const status = state.data.statusByDevice.get(device.id);
        if (!status?.timer_running) return null;
        const remaining = formatRemaining(extrapolatedRemaining(status, now));
        return `${device.name || "Unnamed device"}: ${remaining} remaining`;
      })
      .filter(Boolean);
    const preview = activeTimers.length
      ? `Active timers now:\n${activeTimers.join("\n")}`
      : "No targeted device currently has an active lock countdown.";
    const confirmed = await confirmAction({
      title: "Reset Timer",
      message:
        `${preview}\n\nRestart the lock countdown on ${targets.length} targeted device(s). Devices ` +
        "that are unlocked or have the Lock trigger OFF stay inactive. The cards update from the " +
        "devices after they sync.",
    });
    if (confirmed) await sendAction(RESET_TIMER);
  });

  $("#force-reset").addEventListener("click", async () => {
    const targets = targetDevices();
    if (!targets.length) {
      toast("Select at least one device first.");
      return;
    }
    const confirmed = await confirmAction({
      title: "Force Reset",
      message:
        `Send a factory-reset command to ${targets.length} targeted device(s):\n` +
        `${targets.map((device) => device.name || "Unnamed device").join(", ")}\n\n` +
        "Devices in Debug Mode will NOT be reset. This cannot be undone.",
      typedPhrase: "RESET",
    });
    if (confirmed) await sendAction(FORCE_RESET);
  });

  $("#create-token").addEventListener("click", async () => {
    if (!state.online) {
      toast(actionUnavailableMessage(state.connectionReason), "error");
      return;
    }
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
      toast(`Could not create a token: ${error.message}`, "error");
    } finally {
      setBusy(button, false);
    }
  });

  $("#copy-token").addEventListener("click", async () => {
    try {
      await copyText($("#token-value").textContent);
      toast("Token copied.", "success");
    } catch {
      toast("Copy failed — select the token manually.", "error");
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
    toast("Enrollment token expired — create a new one.", "info");
  }
}

async function sendAction(actionType) {
  if (!requireOnline("#commands-message")) return;
  const targets = commandTargets();
  if (targets.scope === "selected" && targets.deviceIds.length === 0) {
    showMessage("#commands-message", "Select at least one device first.", "error");
    return;
  }
  const button = actionType === FORCE_RESET
    ? $("#force-reset")
    : actionType === LOCK_NOW
      ? $("#lock-devices")
      : $("#reset-timer");
  clearMessage("#commands-message");
  setBusy(button, true);
  try {
    const result = await createAction(
      state.client,
      actionType,
      newIdempotencyKey(),
      targets.scope,
      targets.deviceIds,
    );
    toast(`${COMMAND_LABELS[actionType] ?? actionType} queued for ${result.device_count} device(s).`, "success");
    scheduleRefresh();
  } catch (error) {
    showMessage("#commands-message", error.message, "error");
  } finally {
    setBusy(button, false);
  }
}

function wireSignOut() {
  $("#sign-out").addEventListener("click", async () => {
    const confirmed = await confirmAction({
      title: "Sign out?",
      message:
        "This browser will no longer access your account. The Wasted app keeps running and syncing; existing settings, timers, and queued commands are unchanged. Sign in again to send new commands or view devices.",
      confirmLabel: "Sign out",
      danger: false,
    });
    if (!confirmed) return;
    state.explicitSignOut = true;
    clearEnrollmentToken();
    clearDashboardCache();
    try {
      await signOut(state.client);
      toast("Signed out.", "info");
    } finally {
      state.explicitSignOut = false;
    }
  });
}

function wireHeaderMenu() {
  const header = document.querySelector(".app-header");
  const toggle = $("#menu-toggle");
  const actions = $("#header-actions");
  if (!header || !toggle || !actions) return;

  const setOpen = (open, restoreFocus = false) => {
    header.classList.toggle("menu-open", open);
    toggle.setAttribute("aria-expanded", String(open));
    toggle.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    if (open) {
      actions.querySelector("button:not([hidden])")?.focus({ preventScroll: true });
    } else if (restoreFocus) {
      toggle.focus({ preventScroll: true });
    }
  };

  toggle.addEventListener("click", (event) => {
    event.stopPropagation();
    setOpen(!header.classList.contains("menu-open"));
  });
  document.addEventListener("click", (event) => {
    if (!header.contains(event.target)) setOpen(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && header.classList.contains("menu-open")) {
      setOpen(false, true);
    }
  });
  actions.querySelectorAll("button:not(.menu-copy)").forEach((button) => {
    button.addEventListener("click", () => setOpen(false));
  });
  const desktop = window.matchMedia("(min-width: 641px)");
  desktop.addEventListener?.("change", (event) => {
    if (event.matches) setOpen(false);
  });
}

function closeHeaderMenu() {
  const header = document.querySelector(".app-header");
  if (!header) return;
  header.classList.remove("menu-open");
  const toggle = $("#menu-toggle");
  if (!toggle) return;
  toggle.setAttribute("aria-expanded", "false");
  toggle.setAttribute("aria-label", "Open menu");
}

function syncHeaderMenu() {
  const toggle = $("#menu-toggle");
  const actions = $("#header-actions");
  if (!toggle || !actions) return;
  const visible =
    !$("#menu-connection")?.hidden ||
    [...actions.querySelectorAll("button:not(.menu-copy)")].some((button) => !button.hidden);
  toggle.hidden = !visible;
  if (!visible) closeHeaderMenu();
}

function el(tag, { className, text, attrs, icon } = {}, children = []) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (icon) node.append(iconNode(icon));
  if (text !== undefined) {
    if (tag === "button" || icon) {
      const label = document.createElement("span");
      label.className = "button-label";
      label.textContent = text;
      node.append(label);
    } else {
      node.textContent = text;
    }
  }
  if (attrs) {
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  }
  for (const child of children) node.append(child);
  return node;
}

function iconNode(name) {
  const namespace = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(namespace, "svg");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(namespace, "use");
  use.setAttribute("href", `#icon-${name}`);
  svg.append(use);
  return svg;
}
