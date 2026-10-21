# Capacity and Free-plan guidance

Per-user self-hosting keeps load isolated per Supabase project. This page records the sizing model
so it survives without the development plan.

## Free-plan limits (current)

- Database: 500 MB
- Egress: 5 GB / month
- Monthly active users: 50,000
- Realtime: 2,000,000 messages / month, 200 peak connections
- No PITR; Free projects can be paused after low activity

Review current limits in the Supabase dashboard before relying on them.

## Load model

- One device writes at most one status upsert per heartbeat (60 s) → 43,200/month; the row is
  overwritten, so it does not create 43,200 retained rows.
- Realtime deliveries count once per listening client. With ten devices and one always-open
  dashboard, status delivery is roughly 432,000 messages/month; two open dashboards roughly
  864,000, before settings/command events.
- Conservative estimate: `device_count × 43,200 × concurrently_open_dashboards`.

## Internal review thresholds

Treat these as early warnings, not hard limits:

- 1,000,000 Realtime messages/month
- 160 peak Realtime connections
- 350 MB database size
- 3.5 GB egress/month

At 70% / 85% / 95% of any quota, reduce subscriptions/refetches or status writes, then re-check.
Never promise unlimited free operation.

## Defaults that keep usage low

- Scoped Realtime filters (own device or account only).
- Realtime is only an invalidation signal; dashboards refetch durable state and coalesce refreshes.
- One status row per device (upsert, no history table).
- 60-second heartbeat, not per-second writes.
- Command/status retention is measurable; define an export/retention policy before the database
  approaches the threshold.

## Retention policy (recommended; implement before thresholds)

- `device_status`: current row only (overwritten), no history.
- `device_commands` / `command_events` / `account_actions`: retain **180 days** for auditability;
  export older rows before deletion. Anonymous identities are cleaned daily by the existing job.
- Revoked devices: retain while their command history is needed; after the export window, purge the
  device (cascades its history) or keep it if storage allows. Never purge without an export.
- Define and document a scheduled purge/export job before the database approaches 350 MB or the
  command tables grow unbounded. A purge must be bounded, logged, and reversible via the export.

## What to monitor

- Supabase Usage (database size, egress, MAU) and Realtime reports.
- Command/event row counts and growth.
- Anonymous-identity cleanup job health.

Record the expected device/dashboard count before rollout and check weekly during a soak, monthly
afterward.
