-- Enrollment tokens become independent per device: creating a new token no longer revokes
-- older unused tokens. Tokens remain 256-bit random, SHA-256 hashed, single-use, and expire
-- after ten minutes. The previous behavior forced users to enroll one device at a time.
-- Forward-only migration.

create or replace function public.create_device_enrollment()
returns table (enrollment_id uuid, enrollment_token text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    token text;
    enrollment private.device_enrollments;
begin
    token := encode(extensions.gen_random_bytes(32), 'hex');

    insert into private.device_enrollments (account_id, token_hash, expires_at)
    values (uid, extensions.digest(token, 'sha256'), now() + interval '10 minutes')
    returning * into enrollment;

    return query select enrollment.id, token, enrollment.expires_at;
end;
$$;
