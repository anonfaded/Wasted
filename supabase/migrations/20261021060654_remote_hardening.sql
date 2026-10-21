-- Remote hardening:
--   1. Revocation terminalizes commands already in `executing` (outcome may be unknown).
--   2. Account-action idempotency keys are bound to the requested action type/scope.
--   3. Future functions are not auto-executable by PostgreSQL PUBLIC.
--   4. A schema marker for post-install verification.
-- Forward-only migration.

-- ─── 1. Revocation semantics ────────────────────────────────────────────────

create or replace function public.revoke_device(p_device_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    device public.devices;
begin
    select * into device
      from public.devices d
     where d.id = p_device_id
       and d.account_id = uid
     for update;
    if device.id is null then
        raise exception 'device not found';
    end if;
    if device.revoked_at is not null then
        return;
    end if;

    update public.devices d
       set revoked_at = now(), updated_at = now()
     where d.id = p_device_id;

    -- queued/received: definitely not executed
    with rejected as (
        update public.device_commands c
           set state = 'rejected',
               finished_at = now(),
               result_code = 'device_revoked'
         where c.device_id = p_device_id
           and c.state in ('queued', 'received')
        returning c.id, c.device_id, c.account_id, c.result_code
    )
    insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
    select id, device_id, account_id, 'rejected', result_code from rejected;

    -- executing: the device may already have crossed an irreversible boundary and can no longer
    -- report; record a terminal failed state with an explicit unknown-outcome code.
    with interrupted as (
        update public.device_commands c
           set state = 'failed',
               finished_at = now(),
               result_code = 'device_revoked_during_execution'
         where c.device_id = p_device_id
           and c.state = 'executing'
        returning c.id, c.device_id, c.account_id, c.result_code
    )
    insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
    select id, device_id, account_id, 'failed', result_code from interrupted;
end;
$$;

-- ─── 2. Idempotency binding ──────────────────────────────────────────────────

create or replace function public.create_account_action(
    p_action_type text,
    p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    ttl interval;
    existing public.account_actions;
    action public.account_actions;
    device_count integer;
begin
    if p_action_type is null or p_action_type not in ('reset_timer', 'force_reset') then
        raise exception 'unsupported action type';
    end if;
    if p_idempotency_key is null then
        raise exception 'idempotency key is required';
    end if;

    ttl := case when p_action_type = 'reset_timer'
                then interval '24 hours'
                else interval '10 minutes'
           end;

    select * into existing
      from public.account_actions a
     where a.account_id = uid
       and a.idempotency_key = p_idempotency_key;
    if existing.id is not null then
        if existing.action_type <> p_action_type or existing.device_id is not null then
            raise exception 'idempotency key reused for a different action';
        end if;
        return private.action_result_json(existing);
    end if;

    insert into public.account_actions
        (account_id, action_type, idempotency_key, created_by, expires_at)
    values (uid, p_action_type, p_idempotency_key, uid, now() + ttl)
    returning * into action;

    -- deterministic device ordering prevents deadlocks between concurrent actions
    with targets as (
        select d.id
          from public.devices d
         where d.account_id = uid
           and d.revoked_at is null
         order by d.id
         for update
    ), created_commands as (
        insert into public.device_commands
            (action_id, device_id, account_id, command_type, expires_at)
        select action.id, t.id, uid, p_action_type, action.expires_at
          from targets t
        returning id, device_id, account_id
    )
    insert into public.command_events (command_id, device_id, account_id, event_type)
    select id, device_id, account_id, 'queued' from created_commands;

    select count(*) into device_count
      from public.device_commands c
     where c.action_id = action.id;

    return jsonb_build_object(
        'action_id', action.id,
        'created_at', action.created_at,
        'expires_at', action.expires_at,
        'device_count', device_count
    );
exception
    when unique_violation then
        select * into existing
          from public.account_actions a
         where a.account_id = uid
           and a.idempotency_key = p_idempotency_key;
        if existing.id is not null then
            if existing.action_type <> p_action_type or existing.device_id is not null then
                raise exception 'idempotency key reused for a different action';
            end if;
            return private.action_result_json(existing);
        end if;
        raise;
end;
$$;

-- ─── 3. Future function ACLs ─────────────────────────────────────────────────

alter default privileges for role postgres in schema public
    revoke execute on functions from public;

-- ─── 4. Schema marker ────────────────────────────────────────────────────────

comment on schema public is 'wasted-remote-schema:1';
