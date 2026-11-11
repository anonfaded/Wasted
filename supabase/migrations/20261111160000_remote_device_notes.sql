-- Owner-only device notes. Kept separate from public.devices so the device identity
-- cannot read the owner's private notes through its own devices row.

create table public.device_notes (
    device_id uuid primary key,
    account_id uuid not null,
    notes text not null default '',
    updated_by uuid null references auth.users (id) on delete set null,
    updated_at timestamptz not null default now(),
    constraint device_notes_device_account_fk foreign key (device_id, account_id)
        references public.devices (id, account_id) on delete cascade,
    constraint device_notes_length check (char_length(notes) <= 4000)
);

create index device_notes_account_idx on public.device_notes (account_id);

alter table public.device_notes enable row level security;
alter table public.device_notes force row level security;

create policy device_notes_select_owner on public.device_notes
    for select to authenticated
    using (account_id = (select auth.uid()));

create function public.update_device_notes(
    p_device_id uuid,
    p_notes text
)
returns public.device_notes
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    device public.devices;
    note public.device_notes;
begin
    if p_device_id is null then
        raise exception 'device id is required';
    end if;
    if p_notes is null then
        raise exception 'notes are required';
    end if;
    if char_length(p_notes) > 4000 then
        raise exception 'notes must be 4000 characters or fewer';
    end if;

    select * into device
      from public.devices d
     where d.id = p_device_id
       and d.account_id = uid
       and d.revoked_at is null
     for update;
    if device.id is null then
        raise exception 'device not found';
    end if;

    insert into public.device_notes (device_id, account_id, notes, updated_by)
    values (device.id, uid, p_notes, uid)
    on conflict (device_id) do update set
        notes = excluded.notes,
        updated_by = excluded.updated_by,
        updated_at = now()
    returning * into note;

    return note;
end;
$$;

revoke execute on function public.update_device_notes(uuid, text)
    from public, anon, authenticated;
grant execute on function public.update_device_notes(uuid, text)
    to authenticated;

revoke all on public.device_notes from public, anon, authenticated;
grant select on public.device_notes to authenticated;
