-- Recover an enrolled device's anonymous Auth identity without a new enrollment token.
-- The device proves ownership with the device id and the installation id generated at enrollment;
-- both are stored only in the encrypted on-device credential store. Revoked devices cannot recover.

create function public.recover_device_session(
    p_device_id uuid,
    p_installation_id uuid
)
returns public.devices
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := (select auth.uid());
    device public.devices;
begin
    if uid is null then
        raise exception 'authentication required';
    end if;
    if not private.is_anonymous_user() then
        raise exception 'device recovery requires an anonymous device identity';
    end if;
    if p_device_id is null or p_installation_id is null then
        raise exception 'device identity is required';
    end if;

    select * into device
      from public.devices d
     where d.id = p_device_id
       and d.installation_id = p_installation_id
     for update;
    if device.id is null then
        raise exception 'device not found';
    end if;
    if device.revoked_at is not null then
        raise exception 'device revoked';
    end if;
    if device.auth_user_id = uid then
        return device;
    end if;

    update public.devices d
       set auth_user_id = uid,
           updated_at = now()
     where d.id = device.id
    returning * into device;
    return device;
end;
$$;

revoke execute on function public.recover_device_session(uuid, uuid)
    from public, anon, authenticated;
grant execute on function public.recover_device_session(uuid, uuid)
    to authenticated;
