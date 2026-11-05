-- Display names: allow spaces and normal punctuation, retain trimming and uniqueness.
-- Forward-only migration.

alter table public.accounts drop constraint accounts_handle_length;
alter table public.accounts
    add constraint accounts_handle_length check (char_length(handle) between 1 and 32);

alter table public.accounts drop constraint accounts_handle_charset;
alter table public.accounts
    add constraint accounts_handle_charset check (handle !~ '[[:cntrl:]]');

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

    perform pg_catalog.pg_advisory_xact_lock(741852963);
    if exists (select 1 from public.accounts) then
        raise exception 'owner account already initialized';
    end if;

    if trimmed is null
        or char_length(trimmed) < 1
        or char_length(trimmed) > 32
        or trimmed ~ '[[:cntrl:]]' then
        raise exception 'account name must be 1-32 characters and cannot contain control characters';
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
        or char_length(trimmed) < 1
        or char_length(trimmed) > 32
        or trimmed ~ '[[:cntrl:]]' then
        raise exception 'account name must be 1-32 characters and cannot contain control characters';
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

revoke execute on function public.initialize_owner_account(text) from public, anon, authenticated;
grant execute on function public.initialize_owner_account(text) to authenticated;
revoke execute on function public.update_owner_handle(text) from public, anon, authenticated;
grant execute on function public.update_owner_handle(text) to authenticated;

comment on schema public is 'wasted-remote-schema:3';
