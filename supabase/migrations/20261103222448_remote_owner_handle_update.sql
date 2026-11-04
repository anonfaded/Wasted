-- Owner profile: allow the signed-in owner to change the dashboard account name.
-- Forward-only migration.

create or replace function public.update_owner_handle(p_handle text)
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

    if trimmed is null
        or char_length(trimmed) < 3
        or char_length(trimmed) > 32
        or trimmed !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$' then
        raise exception 'handle must be 3-32 characters: letters, digits, dot, dash, underscore';
    end if;

    update public.accounts a
       set handle = trimmed
     where a.id = uid
     returning * into account;

    if account.id is null then
        raise exception 'owner account missing';
    end if;

    return account;
exception
    when unique_violation then
        raise exception 'handle is already taken';
end;
$$;

revoke execute on function public.update_owner_handle(text) from public, anon, authenticated;
grant execute on function public.update_owner_handle(text) to authenticated;

comment on schema public is 'wasted-remote-schema:2';
