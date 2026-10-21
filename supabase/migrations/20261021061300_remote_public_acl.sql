-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default. Per-schema default privileges
-- are additive to the global defaults, so the PUBLIC revoke must be global to be effective.
-- Forward-only migration.

alter default privileges for role postgres
    revoke execute on functions from public;
