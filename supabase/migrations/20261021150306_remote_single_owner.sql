-- Single-owner guard: a self-hosted project has one dashboard owner. Random authenticated users
-- may still exist in Auth, but they cannot initialize a second dashboard account.
-- Forward-only migration.

create or replace function public.initialize_owner_account(p_handle text)
returns public.accounts
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := (select auth.uid());
    trimmed text := btrim(p_handle);
    account public.accounts;
begin
    if uid is null then
        raise exception 'authentication required';
    end if;
    if private.is_anonymous_user() then
        raise exception 'owner account required';
    end if;

    select * into account from public.accounts a where a.id = uid;
    if account.id is not null then
        return account;
    end if;

    -- Serialize owner bootstrap and reject a second dashboard account.
    perform pg_catalog.pg_advisory_xact_lock(741852963);
    if exists (select 1 from public.accounts) then
        raise exception 'owner account already initialized';
    end if;

    if trimmed is null
        or char_length(trimmed) < 3
        or char_length(trimmed) > 32
        or trimmed !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$' then
        raise exception 'handle must be 3-32 characters: letters, digits, dot, dash, underscore';
    end if;

    insert into public.accounts (id, handle) values (uid, trimmed)
    returning * into account;
    insert into public.account_settings (account_id) values (uid);

    return account;
exception
    when unique_violation then
        select * into account from public.accounts a where a.id = uid;
        if account.id is not null then
            return account;
        end if;
        raise;
end;
$$;

revoke execute on function public.initialize_owner_account(text) from public, anon, authenticated;
grant execute on function public.initialize_owner_account(text) to authenticated;
