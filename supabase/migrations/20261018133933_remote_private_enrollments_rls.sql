-- Defense in depth: private.device_enrollments is unreachable through the Data API
-- (schema not exposed, usage and table privileges revoked from client roles), but RLS is
-- enabled + forced anyway so a future exposure mistake still denies all client access.
-- postgres/service_role bypass RLS, so the definer RPCs are unaffected.
-- Forward-only migration.

alter table private.device_enrollments enable row level security;
alter table private.device_enrollments force row level security;
