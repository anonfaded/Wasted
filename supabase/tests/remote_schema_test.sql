-- Remote schema tests: tables, constraints, indexes, consistency trigger, cascade behavior,
-- and Realtime publication membership. Wrapped in a transaction that is rolled back, so the
-- database is unchanged. Run via Supabase MCP after migrations 001–004.

begin;

create function pg_temp.assert_true(p_condition boolean, p_message text)
returns void
language plpgsql
as $$
begin
    if not coalesce(p_condition, false) then
        raise exception 'assertion failed: %', p_message;
    end if;
end;
$$;

create function pg_temp.expect_error(p_sql text, p_state text default null)
returns void
language plpgsql
as $$
begin
    begin
        execute p_sql;
    exception when others then
        if p_state is null or sqlstate = p_state then
            return;
        end if;
        raise exception 'expected sqlstate %, got % (%) for: %', p_state, sqlstate, sqlerrm, p_sql;
    end;
    raise exception 'expected an error but the statement succeeded: %', p_sql;
end;
$$;

-- ─── Fixture identities for constraint tests ─────────────────────────────────

insert into auth.users (instance_id, id, aud, role, created_at, updated_at, is_anonymous) values
    ('00000000-0000-0000-0000-000000000000', '0d0d0d0d-0000-4000-8000-0000000000d1', 'authenticated', 'authenticated', now(), now(), false),
    ('00000000-0000-0000-0000-000000000000', '0d0d0d0d-0000-4000-8000-0000000000d2', 'authenticated', 'authenticated', now(), now(), false),
    ('00000000-0000-0000-0000-000000000000', '0d0d0d0d-0000-4000-8000-0000000000d3', 'authenticated', 'authenticated', now(), now(), true);

-- ─── Structure ───────────────────────────────────────────────────────────────

do $$
declare
    target text;
begin
    foreach target in array array[
        'accounts', 'devices', 'account_settings', 'device_status',
        'account_actions', 'device_commands', 'command_events'
    ] loop
        perform pg_temp.assert_true(
            to_regclass('public.' || target) is not null,
            'missing table public.' || target
        );
    end loop;

    perform pg_temp.assert_true(
        to_regclass('private.device_enrollments') is not null,
        'missing table private.device_enrollments'
    );

    foreach target in array array[
        'accounts_handle_lower_uidx', 'devices_account_active_idx',
        'device_status_account_seen_idx', 'account_actions_account_created_idx',
        'device_commands_device_pending_idx', 'device_commands_account_created_idx',
        'command_events_command_created_idx', 'command_events_account_created_idx'
    ] loop
        perform pg_temp.assert_true(
            to_regclass('public.' || target) is not null,
            'missing index public.' || target
        );
    end loop;

    perform pg_temp.assert_true(
        to_regclass('private.device_enrollments_account_open_idx') is not null,
        'missing index private.device_enrollments_account_open_idx'
    );
end;
$$;

-- ─── Constraint behavior ─────────────────────────────────────────────────────

select pg_temp.expect_error(
    $$insert into public.accounts (id, handle) values ('0d0d0d0d-0000-4000-8000-0000000000d1', 'ab')$$,
    '23514'
);
select pg_temp.expect_error(
    $$insert into public.accounts (id, handle) values ('0d0d0d0d-0000-4000-8000-0000000000d1', ' padded ')$$,
    '23514'
);
select pg_temp.expect_error(
    $$insert into public.accounts (id, handle) values ('0d0d0d0d-0000-4000-8000-0000000000d1', '_bad')$$,
    '23514'
);

insert into public.accounts (id, handle) values ('0d0d0d0d-0000-4000-8000-0000000000d1', 'CaseTest');
select pg_temp.expect_error(
    $$insert into public.accounts (id, handle) values ('0d0d0d0d-0000-4000-8000-0000000000d2', 'casetest')$$,
    '23505'
);

insert into public.account_settings (account_id) values ('0d0d0d0d-0000-4000-8000-0000000000d1');

-- device checks
select pg_temp.expect_error(
    $$insert into public.devices (account_id, auth_user_id, installation_id, name)
      values ('0d0d0d0d-0000-4000-8000-0000000000d1', null, '2d000000-0000-4000-8000-0000000000d1', 'No Auth')$$,
    '23514'
);
select pg_temp.expect_error(
    $$insert into public.devices (account_id, auth_user_id, installation_id, name)
      values ('0d0d0d0d-0000-4000-8000-0000000000d1', '0d0d0d0d-0000-4000-8000-0000000000d3', '2d000000-0000-4000-8000-0000000000d1', '   ')$$,
    '23514'
);

insert into public.devices (id, account_id, auth_user_id, installation_id, name)
values ('dd000000-0000-4000-8000-0000000000d1', '0d0d0d0d-0000-4000-8000-0000000000d1',
        '0d0d0d0d-0000-4000-8000-0000000000d3', '2d000000-0000-4000-8000-0000000000d1', 'Device One');

-- command/action consistency trigger
insert into public.account_actions (id, account_id, action_type, idempotency_key, expires_at)
values ('aa000000-0000-4000-8000-0000000000d1', '0d0d0d0d-0000-4000-8000-0000000000d1',
        'reset_timer', 'cc000000-0000-4000-8000-0000000000d1', now() + interval '24 hours');

select pg_temp.expect_error(
    $$insert into public.device_commands (action_id, device_id, account_id, command_type, expires_at)
      values ('aa000000-0000-4000-8000-0000000000d1', 'dd000000-0000-4000-8000-0000000000d1',
              '0d0d0d0d-0000-4000-8000-0000000000d2', 'reset_timer', now() + interval '24 hours')$$,
    'P0001'
);
select pg_temp.expect_error(
    $$insert into public.device_commands (action_id, device_id, account_id, command_type, expires_at)
      values ('aa000000-0000-4000-8000-0000000000d1', 'dd000000-0000-4000-8000-0000000000d1',
              '0d0d0d0d-0000-4000-8000-0000000000d1', 'force_reset', now() + interval '24 hours')$$,
    'P0001'
);
select pg_temp.expect_error(
    $$insert into public.device_commands (action_id, device_id, account_id, command_type, expires_at)
      values ('aa000000-0000-4000-8000-0000000000d1', 'dd000000-0000-4000-8000-0000000000d1',
              '0d0d0d0d-0000-4000-8000-0000000000d1', 'reset_timer', now() + interval '1 hour')$$,
    'P0001'
);

insert into public.device_commands (id, action_id, device_id, account_id, command_type, expires_at)
values ('ee000000-0000-4000-8000-0000000000d1', 'aa000000-0000-4000-8000-0000000000d1',
        'dd000000-0000-4000-8000-0000000000d1', '0d0d0d0d-0000-4000-8000-0000000000d1',
        'reset_timer', now() + interval '24 hours');

select pg_temp.expect_error(
    $$insert into public.device_commands (action_id, device_id, account_id, command_type, expires_at)
      values ('aa000000-0000-4000-8000-0000000000d1', 'dd000000-0000-4000-8000-0000000000d1',
              '0d0d0d0d-0000-4000-8000-0000000000d1', 'reset_timer', now() + interval '24 hours')$$,
    '23505'
);

-- cascade behavior: deleting the account removes everything below it
delete from public.accounts where id = '0d0d0d0d-0000-4000-8000-0000000000d1';

do $$
begin
    perform pg_temp.assert_true(
        (select count(*) from public.devices where account_id = '0d0d0d0d-0000-4000-8000-0000000000d1') = 0,
        'devices should cascade from accounts'
    );
    perform pg_temp.assert_true(
        (select count(*) from public.account_settings where account_id = '0d0d0d0d-0000-4000-8000-0000000000d1') = 0,
        'account_settings should cascade from accounts'
    );
    perform pg_temp.assert_true(
        (select count(*) from public.account_actions where account_id = '0d0d0d0d-0000-4000-8000-0000000000d1') = 0,
        'account_actions should cascade from accounts'
    );
    perform pg_temp.assert_true(
        (select count(*) from public.device_commands where account_id = '0d0d0d0d-0000-4000-8000-0000000000d1') = 0,
        'device_commands should cascade from accounts'
    );
end;
$$;

-- ─── Realtime publication membership ─────────────────────────────────────────

do $$
declare
    public_tables integer;
begin
    select count(*) into public_tables
      from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public';

    perform pg_temp.assert_true(public_tables = 4,
        'realtime publication should contain exactly the 4 remote tables, found ' || public_tables);

    perform pg_temp.assert_true(
        (select count(*) from pg_publication_tables
          where pubname = 'supabase_realtime'
            and tablename in ('account_settings', 'devices', 'device_status', 'device_commands')) = 4,
        'all four remote tables must be published'
    );

    perform pg_temp.assert_true(
        not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime'
                       and tablename in ('accounts', 'account_actions', 'command_events')),
        'accounts, account_actions, and command_events must not be published'
    );
end;
$$;

rollback;
