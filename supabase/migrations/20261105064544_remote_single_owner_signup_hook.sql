-- Server-side signup gate: allow the first non-anonymous owner and anonymous devices only.
-- Enable this function in Authentication > Hooks > Before User Created.
-- Forward-only migration.

create or replace function public.hook_single_owner_signup(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    is_anonymous boolean := coalesce((event->'user'->>'is_anonymous')::boolean, false);
begin
    -- Device identities are anonymous and must always be allowed.
    if is_anonymous then
        return '{}'::jsonb;
    end if;

    -- Serialize concurrent signup attempts so only one owner can pass.
    perform pg_catalog.pg_advisory_xact_lock(741852963);

    if exists (select 1 from public.accounts)
        or exists (
            select 1
              from auth.users u
             where u.is_anonymous = false
               and u.email is not null
        ) then
        return jsonb_build_object(
            'error', jsonb_build_object(
                'message', 'This dashboard already has an owner. Sign in instead.',
                'http_code', 403
            )
        );
    end if;

    return '{}'::jsonb;
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.hook_single_owner_signup(jsonb) to supabase_auth_admin;
revoke execute on function public.hook_single_owner_signup(jsonb) from public, anon, authenticated;

comment on schema public is 'wasted-remote-schema:4';
