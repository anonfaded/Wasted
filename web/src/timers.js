export const FRESHNESS_WINDOW_MS = 150_000;

/** Formats remaining seconds as (Nd) HH:MM:SS. */
export function formatRemaining(totalSeconds) {
  const s = Math.max(0, Math.floor(Number(totalSeconds) || 0));
  const days = Math.floor(s / 86400);
  const hours = Math.floor((s % 86400) / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  const seconds = s % 60;
  const hms = [hours, minutes, seconds].map((v) => String(v).padStart(2, "0")).join(":");
  return days > 0 ? `${days}d ${hms}` : hms;
}

/** Extrapolates a running timer locally from the last server sample. */
export function extrapolatedRemaining(status, nowMs) {
  if (!status || !status.timer_running) return 0;
  const sampled = Date.parse(status.timer_sampled_at);
  const base = Number(status.timer_remaining_seconds) || 0;
  if (Number.isNaN(sampled)) return Math.max(0, base);
  const elapsed = Math.max(0, Math.floor((nowMs - sampled) / 1000));
  return Math.max(0, base - elapsed);
}

/** A device is "recently connected" when its last contact is within the plan's 150s window. */
export function isRecentlyConnected(status, nowMs) {
  if (!status || !status.last_seen_at) return false;
  const seen = Date.parse(status.last_seen_at);
  if (Number.isNaN(seen)) return false;
  return nowMs - seen <= FRESHNESS_WINDOW_MS;
}

/** Exact last-contact label; never hides staleness. */
export function formatLastContact(status) {
  if (!status || !status.last_seen_at) return "never";
  const seen = Date.parse(status.last_seen_at);
  if (Number.isNaN(seen)) return status.last_seen_at;
  return new Date(seen).toLocaleString();
}
