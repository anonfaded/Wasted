-- RPC tests: init, enrollment, claim, reconcile, settings revision, actions/idempotency,
-- transitions/events, expiry, revocation, and clean re-enrollment. Rolled-back transaction;
-- run via Supabase MCP after migrations 001-004.

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

create function pg_temp.expect_error(p_sql text, p_state text default null, p_message_like text default null)
returns void
language plpgsql
as $$
begin
    begin
        execute p_sql;
    exception when others then
        if p_state is not null and sqlstate <> p_state then
            raise exception 'expected sqlstate %, got % (%) for: %', p_state, sqlstate, sqlerrm, p_sql;
        end if;
        if p_message_like is not null and position(p_message_like in sqlerrm) = 0 then
            raise exception 'expected message containing %, got % for: %', p_message_like, sqlerrm, p_sql;
        end if;
        return;
    end;
    raise exception 'expected an error but the statement succeeded: %', p_sql;
end;
$$;

-- ─── Fixtures ────────────────────────────────────────────────────────────────

insert into auth.users (instance_id, id, aud, role, created_at, updated_at, is_anonymous) values
    ('00000000-0000-0000-0000-000000000000', '0a0a0a0a-0000-4000-8000-0000000000a1', 'authenticated', 'authenticated', now(), now(), false),
    ('00000000-0000-0000-0000-000000000000', '0a1a1a1a-0000-4000-8000-0000000000a1', 'authenticated', 'authenticated', now(), now(), true),
    ('00000000-0000-0000-0000-000000000000', '0c0c0c0c-0000-4000-8000-0000000000c1', 'authenticated', 'authenticated', now(), now(), true),
    ('00000000-0000-0000-0000-000000000000', '0c0c0c0c-0000-4000-8000-0000000000c2', 'authenticated', 'authenticated', now(), now(), true);

-- ─── Owner: initialize ───────────────────────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a0a0a0a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":false}', true);

do $$
declare
    account public.accounts;
begin
    account := public.initialize_owner_account('RpcOwnerA');
    perform pg_temp.assert_true(account.handle = 'RpcOwnerA', 'handle must be stored');
    perform pg_temp.assert_true(account.id = '0a0a0a0a-0000-4000-8000-0000000000a1', 'account id must equal auth uid');

    account := public.initialize_owner_account('AnotherName');
    perform pg_temp.assert_true(account.handle = 'RpcOwnerA', 'init must be idempotent for the same user');
end;
$$;

-- anonymous callers are rejected
select set_config('request.jwt.claims',
    '{"sub":"0c0c0c0c-0000-4000-8000-0000000000c2","role":"authenticated","is_anonymous":true}', true);
select pg_temp.expect_error(
    $$select public.initialize_owner_account('AnonAttempt')$$,
    'P0001', 'owner account required'
);

-- ─── Owner: enrollments ──────────────────────────────────────────────────────

select set_config('request.jwt.claims',
    '{"sub":"0a0a0a0a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":false}', true);

create temp table pg_temp.t_enroll_first as
    select now() as at, e.* from public.create_device_enrollment() e;
create temp table pg_temp.t_enroll_second as
    select now() as at, e.* from public.create_device_enrollment() e;

do $$
begin
    perform pg_temp.assert_true(
        (select enrollment_token ~ '^[0-9a-f]{64}$' from pg_temp.t_enroll_second),
        'enrollment token must be 64 lowercase hex characters'
    );
    perform pg_temp.assert_true(
        (select enrollment_token <> (select enrollment_token from pg_temp.t_enroll_first)
           from pg_temp.t_enroll_second),
        'each enrollment must generate a fresh token'
    );
    perform pg_temp.assert_true(
        (select expires_at between at + interval '9 minutes' and at + interval '11 minutes'
           from pg_temp.t_enroll_second),
        'enrollment must expire after ~10 minutes'
    );
end;
$$;

reset role;

do $$
begin
    perform pg_temp.assert_true(
        (select revoked_at is not null from private.device_enrollments
          where id = (select enrollment_id from pg_temp.t_enroll_first)),
        'older unused enrollment must be revoked when a new one is created'
    );
    perform pg_temp.assert_true(
        (select revoked_at is null and consumed_at is null from private.device_enrollments
          where id = (select enrollment_id from pg_temp.t_enroll_second)),
        'newest enrollment must stay open'
    );
end;
$$;

-- ─── Device: claim ───────────────────────────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a1a1a1a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":true}', true);

create temp table pg_temp.t_claim as
    select d.* from public.claim_device_enrollment(
        (select enrollment_token from pg_temp.t_enroll_second),
        '1a000000-0000-4000-8000-0000000000f1',
        'Claimed Device',
        1440,
        true
    ) d;

do $$
declare
    replay public.devices;
begin
    perform pg_temp.assert_true(
        (select account_id = '0a0a0a0a-0000-4000-8000-0000000000a1' from pg_temp.t_claim),
        'device must bind to the enrolling account'
    );
    perform pg_temp.assert_true(
        (select name = 'Claimed Device' from pg_temp.t_claim),
        'device name must be stored'
    );

    -- lost-response replay: same identity + installation returns the same device
    replay := public.claim_device_enrollment(
        (select enrollment_token from pg_temp.t_enroll_second),
        '1a000000-0000-4000-8000-0000000000f1',
        'Claimed Device',
        1440,
        true
    );
    perform pg_temp.assert_true(
        replay.id = (select id from pg_temp.t_claim),
        'replay must return the same device, not create a duplicate'
    );
end;
$$;

-- wrong token shape is rejected before any lookup
select pg_temp.expect_error(
    $$select public.claim_device_enrollment('NOTHEX', '1a000000-0000-4000-8000-0000000000f2', 'X', 60, false)$$,
    'P0001', '64 lowercase hex'
);

reset role;

do $$
begin
    perform pg_temp.assert_true(
        (select consumed_at is not null and consumed_by_device_id = (select id from pg_temp.t_claim)
           from private.device_enrollments
          where id = (select enrollment_id from pg_temp.t_enroll_second)),
        'token must be consumed by the created device'
    );
    perform pg_temp.assert_true(
        (select count(*) from public.devices where installation_id = '1a000000-0000-4000-8000-0000000000f1') = 1,
        'exactly one device row per installation id'
    );
    perform pg_temp.assert_true(
        (select revision = 1 and lock_timer_minutes = 1440 and usb_trigger_enabled = true
                and initialized_at is not null
           from public.account_settings where account_id = '0a0a0a0a-0000-4000-8000-0000000000a1'),
        'first claim must seed settings from the validated local values with revision 1'
    );
end;
$$;

-- owner callers cannot claim; consumed tokens cannot be reused by another identity
set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a0a0a0a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":false}', true);
select pg_temp.expect_error(
    $$select public.claim_device_enrollment(
        (select enrollment_token from pg_temp.t_enroll_second),
        '1a000000-0000-4000-8000-0000000000f9', 'X', 60, false)$$,
    'P0001', 'anonymous device identity'
);

select set_config('request.jwt.claims',
    '{"sub":"0c0c0c0c-0000-4000-8000-0000000000c1","role":"authenticated","is_anonymous":true}', true);
select pg_temp.expect_error(
    $$select public.claim_device_enrollment(
        (select enrollment_token from pg_temp.t_enroll_second),
        '1a000000-0000-4000-8000-0000000000f3', 'X', 60, false)$$,
    'P0001', 'already used'
);

-- expired token is rejected
reset role;
insert into private.device_enrollments (account_id, token_hash, expires_at, created_at)
values ('0a0a0a0a-0000-4000-8000-0000000000a1',
        extensions.digest(repeat('e', 64), 'sha256'),
        now() - interval '30 minutes',
        now() - interval '1 hour');

set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0c0c0c0c-0000-4000-8000-0000000000c2","role":"authenticated","is_anonymous":true}', true);
select pg_temp.expect_error(
    $$select public.claim_device_enrollment(repeat('e', 64), '1a000000-0000-4000-8000-0000000000f4', 'X', 60, false)$$,
    'P0001', 'expired'
);

-- ─── Device: reconcile ───────────────────────────────────────────────────────

select set_config('request.jwt.claims',
    '{"sub":"0a1a1a1a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":true}', true);

create temp table pg_temp.t_reconcile as
    select public.device_reconcile(
        (select id from pg_temp.t_claim),
        1, 1440, true, 0, false, true, true, true, '2.0.0', 34
    ) as result;

do $$
begin
    perform pg_temp.assert_true(
        (select (result->>'server_time') is not null from pg_temp.t_reconcile),
        'reconcile must return server time'
    );
    perform pg_temp.assert_true(
        (select (result->'settings'->>'revision')::bigint = 1 from pg_temp.t_reconcile),
        'reconcile must return desired settings revision'
    );
    perform pg_temp.assert_true(
        (select (result->'settings'->>'lock_timer_minutes')::integer = 1440 from pg_temp.t_reconcile),
        'reconcile must return desired lock timer'
    );
    perform pg_temp.assert_true(
        (select result->'commands' = '[]'::jsonb from pg_temp.t_reconcile),
        'no commands expected before any action'
    );
end;
$$;

do $$
begin
    perform public.device_reconcile(
        (select id from pg_temp.t_claim),
        1, 1440, true, 120, true, true, true, true, '2.0.0', 34
    );
end;
$$;

reset role;

do $$
begin
    perform pg_temp.assert_true(
        (select count(*) from public.device_status where device_id = (select id from pg_temp.t_claim)) = 1,
        'status must be a single upserted row'
    );
    perform pg_temp.assert_true(
        (select timer_running and timer_remaining_seconds = 120
           from public.device_status where device_id = (select id from pg_temp.t_claim)),
        'status must reflect the latest reconcile values'
    );
end;
$$;

-- ─── Owner: settings revision ────────────────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a0a0a0a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":false}', true);

select pg_temp.expect_error(
    $$select public.update_account_settings(99, 2000, true)$$,
    'P0001', 'revision conflict'
);

do $$
declare
    settings public.account_settings;
begin
    settings := public.update_account_settings(1, 2000, true);
    perform pg_temp.assert_true(settings.revision = 2, 'revision must increment exactly once');
    perform pg_temp.assert_true(settings.lock_timer_minutes = 2000, 'lock timer must update');
end;
$$;

select pg_temp.expect_error(
    $$select public.update_account_settings(1, 3000, false)$$,
    'P0001', 'revision conflict'
);

-- ─── Owner: actions and idempotency ──────────────────────────────────────────

create temp table pg_temp.t_act_reset as
    select public.create_account_action('reset_timer', 'dd000000-0000-4000-8000-0000000000e1') as result;

create temp table pg_temp.t_act_force as
    select public.create_account_action('force_reset', 'dd000000-0000-4000-8000-0000000000e2') as result;

do $$
declare
    duplicate jsonb;
begin
    perform pg_temp.assert_true(
        (select (result->>'device_count')::integer = 1 from pg_temp.t_act_reset),
        'action must target the single active device'
    );
    perform pg_temp.assert_true(
        (select (result->>'expires_at')::timestamptz - (result->>'created_at')::timestamptz
                between interval '23 hours 59 minutes' and interval '24 hours 1 minute'
           from pg_temp.t_act_reset),
        'reset_timer TTL must be 24 hours'
    );
    perform pg_temp.assert_true(
        (select (result->>'expires_at')::timestamptz - (result->>'created_at')::timestamptz
                between interval '9 minutes 59 seconds' and interval '10 minutes 1 second'
           from pg_temp.t_act_force),
        'force_reset TTL must be 10 minutes'
    );

    duplicate := public.create_account_action('reset_timer', 'dd000000-0000-4000-8000-0000000000e1');
    perform pg_temp.assert_true(
        (duplicate->>'action_id') = (select result->>'action_id' from pg_temp.t_act_reset),
        'duplicate key must return the original action'
    );
    perform pg_temp.assert_true(
        (duplicate->>'device_count')::integer = 1,
        'duplicate key must not create additional commands'
    );
end;
$$;

select pg_temp.expect_error(
    $$select public.create_account_action('unsupported_type', 'dd000000-0000-4000-8000-0000000000ef')$$,
    'P0001', 'unsupported action type'
);

-- ─── Device: command transitions ─────────────────────────────────────────────

select set_config('request.jwt.claims',
    '{"sub":"0a1a1a1a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":true}', true);

do $$
declare
    device_id uuid := (select id from pg_temp.t_claim);
    reset_cmd uuid;
    force_cmd uuid;
    command public.device_commands;
begin
    select c.id into reset_cmd
      from public.device_commands c
     where c.command_type = 'reset_timer'
     order by c.created_at limit 1;
    select c.id into force_cmd
      from public.device_commands c
     where c.command_type = 'force_reset'
     order by c.created_at limit 1;

    perform pg_temp.assert_true(reset_cmd is not null and force_cmd is not null,
        'both commands must be visible to the device');

    command := public.device_transition_command(device_id, reset_cmd, 'queued', 'received');
    perform pg_temp.assert_true(command.state = 'received' and command.received_at is not null,
        'receive must stamp received_at');

    perform pg_temp.expect_error(
        format($$select public.device_transition_command(%L, %L, 'queued', 'received')$$, device_id, reset_cmd),
        'P0001', 'state conflict');

    command := public.device_transition_command(device_id, reset_cmd, 'received', 'executing');
    perform pg_temp.assert_true(command.executing_at is not null, 'executing must stamp executing_at');

    command := public.device_transition_command(device_id, reset_cmd, 'executing', 'applied');
    perform pg_temp.assert_true(command.state = 'applied' and command.finished_at is not null,
        'applied must be terminal with finished_at');

    perform pg_temp.expect_error(
        format($$select public.device_transition_command(%L, %L, 'applied', 'received')$$, device_id, reset_cmd),
        'P0001', 'illegal transition');

    command := public.device_transition_command(device_id, force_cmd, 'queued', 'received');
    command := public.device_transition_command(device_id, force_cmd, 'received', 'executing');
    command := public.device_transition_command(device_id, force_cmd, 'executing', 'reset_initiated');
    perform pg_temp.assert_true(command.state = 'reset_initiated',
        'force reset must reach reset_initiated and stop');
end;
$$;

reset role;

do $$
declare
    reset_cmd uuid := (select id from public.device_commands where command_type = 'reset_timer' order by created_at limit 1);
    force_cmd uuid := (select id from public.device_commands where command_type = 'force_reset' order by created_at limit 1);
begin
    perform pg_temp.assert_true(
        (select count(*) from public.command_events where command_id = reset_cmd) = 4,
        'reset_timer must have exactly queued/received/executing/applied events'
    );
    perform pg_temp.assert_true(
        (select count(*) from public.command_events where command_id = force_cmd) = 4,
        'force_reset must have exactly queued/received/executing/reset_initiated events'
    );
end;
$$;

-- ─── Expiry: device-lazy and owner-triggered ─────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a0a0a0a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":false}', true);

do $$
begin
    perform (select public.create_account_action('reset_timer', 'dd000000-0000-4000-8000-0000000000e3'));
    perform (select public.create_account_action('reset_timer', 'dd000000-0000-4000-8000-0000000000e5'));
end;
$$;

reset role;

-- backdate the newest queued command so it is overdue (the second one is backdated later,
-- after the lazy-expiry reconcile, so the owner-triggered path still has work to do)
update public.device_commands set expires_at = now() - interval '1 minute'
 where state = 'queued'
   and action_id in (
       select id from public.account_actions
        where idempotency_key = 'dd000000-0000-4000-8000-0000000000e3'
   );

set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a1a1a1a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":true}', true);

do $$
declare
    device_id uuid := (select id from pg_temp.t_claim);
    overdue_cmd uuid;
begin
    select c.id into overdue_cmd
      from public.device_commands c
     where c.state = 'queued' and c.expires_at <= now()
     order by c.created_at limit 1;

    perform pg_temp.expect_error(
        format($$select public.device_transition_command(%L, %L, 'queued', 'received')$$, device_id, overdue_cmd),
        'P0001', 'expired');

    -- reconcile lazily expires the overdue command and stops returning it
    perform public.device_reconcile(device_id, 2, 2000, true, 0, false, true, true, true, '2.0.0', 34);
end;
$$;

reset role;

do $$
begin
    perform pg_temp.assert_true(
        (select state = 'expired' and result_code = 'expired'
           from public.device_commands
          where action_id = (select id from public.account_actions
                              where idempotency_key = 'dd000000-0000-4000-8000-0000000000e3')),
        'reconcile must lazily expire overdue commands'
    );
    perform pg_temp.assert_true(
        (select count(*) from public.command_events
          where command_id = (select id from public.device_commands
                               where action_id = (select id from public.account_actions
                                                   where idempotency_key = 'dd000000-0000-4000-8000-0000000000e3'))
            and event_type = 'expired') = 1,
        'lazy expiry must append exactly one event'
    );
end;
$$;

-- backdate the remaining queued command for the owner-triggered expiry path
update public.device_commands set expires_at = now() - interval '1 minute'
 where state = 'queued'
   and action_id in (
       select id from public.account_actions
        where idempotency_key = 'dd000000-0000-4000-8000-0000000000e5'
   );

-- owner-triggered expiry for the remaining overdue command
set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a0a0a0a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":false}', true);

do $$
declare
    expired integer;
begin
    expired := public.expire_account_commands();
    perform pg_temp.assert_true(expired >= 1, 'owner expiry must transition the remaining overdue command');
end;
$$;

reset role;

do $$
begin
    perform pg_temp.assert_true(
        (select state = 'expired'
           from public.device_commands
          where action_id = (select id from public.account_actions
                              where idempotency_key = 'dd000000-0000-4000-8000-0000000000e5')),
        'owner-triggered expiry must mark the command expired'
    );
end;
$$;

-- ─── Revocation and clean re-enrollment ──────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a0a0a0a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":false}', true);

-- a fresh queued command must be rejected by revocation
do $$
begin
    perform (select public.create_account_action('reset_timer', 'dd000000-0000-4000-8000-0000000000e4'));
end;
$$;

do $$
declare
    device_id uuid := (select id from pg_temp.t_claim);
begin
    perform public.revoke_device(device_id);
    -- idempotent: revoking again is a no-op
    perform public.revoke_device(device_id);
end;
$$;

reset role;

do $$
declare
    device_id uuid := (select id from pg_temp.t_claim);
begin
    perform pg_temp.assert_true(
        (select revoked_at is not null from public.devices where id = device_id),
        'revocation must be server-stamped'
    );
    perform pg_temp.assert_true(
        (select state = 'rejected' and result_code = 'device_revoked'
           from public.device_commands
          where action_id = (select id from public.account_actions
                              where idempotency_key = 'dd000000-0000-4000-8000-0000000000e4')),
        'queued commands must be rejected on revocation'
    );
    perform pg_temp.assert_true(
        (select state = 'expired'
           from public.device_commands
          where action_id = (select id from public.account_actions
                              where idempotency_key = 'dd000000-0000-4000-8000-0000000000e3')),
        'terminal commands must stay untouched by revocation'
    );
end;
$$;

-- revoked device can no longer reconcile or see anything
set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a1a1a1a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":true}', true);

select pg_temp.expect_error(
    format($$select public.device_reconcile(%L, 2, 2000, true, 0, false, true, true, true, '2.0.0', 34)$$,
           (select id from pg_temp.t_claim)),
    'P0001', 'active device not found'
);

do $$
begin
    perform pg_temp.assert_true(
        not exists (select 1 from public.devices),
        'revoked device must see no device rows'
    );
end;
$$;

-- clean re-enrollment after revocation with a fresh identity + token
reset role;
insert into auth.users (instance_id, id, aud, role, created_at, updated_at, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', '0d0d0d0d-0000-4000-8000-0000000000d9',
        'authenticated', 'authenticated', now(), now(), true);

set local role authenticated;
select set_config('request.jwt.claims',
    '{"sub":"0a0a0a0a-0000-4000-8000-0000000000a1","role":"authenticated","is_anonymous":false}', true);

create temp table pg_temp.t_enroll_third as
    select now() as at, e.* from public.create_device_enrollment() e;

select set_config('request.jwt.claims',
    '{"sub":"0d0d0d0d-0000-4000-8000-0000000000d9","role":"authenticated","is_anonymous":true}', true);

do $$
declare
    new_device public.devices;
begin
    new_device := public.claim_device_enrollment(
        (select enrollment_token from pg_temp.t_enroll_third),
        '1d000000-0000-4000-8000-0000000000f9',
        'Replacement Device',
        2000,
        true
    );
    perform pg_temp.assert_true(new_device.revoked_at is null, 'replacement device must be active');
end;
$$;

reset role;

do $$
begin
    perform pg_temp.assert_true(
        (select count(*) from public.devices where account_id = '0a0a0a0a-0000-4000-8000-0000000000a1') = 2,
        'account must hold the revoked device and the replacement device'
    );
    perform pg_temp.assert_true(
        (select revision = 2 and lock_timer_minutes = 2000
           from public.account_settings where account_id = '0a0a0a0a-0000-4000-8000-0000000000a1'),
        'initialized settings must not be overwritten by later claims'
    );
end;
$$;

rollback;
