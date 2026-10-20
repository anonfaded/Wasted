-- Maintenance: one daily cleanup of unbound/revoked anonymous auth identities.
-- Devices keep audit history via devices.auth_user_id on delete set null.
-- Forward-only migration.

create extension if not exists pg_cron;

do $$
begin
    if exists (select 1 from cron.job where jobname = 'wasted-cleanup-anonymous-identities') then
        perform cron.unschedule('wasted-cleanup-anonymous-identities');
    end if;
end $$;

select cron.schedule(
    'wasted-cleanup-anonymous-identities',
    '30 3 * * *',
    $job$
    -- anonymous identities older than 24 hours that never bound to a device
    delete from auth.users u
     where u.is_anonymous is true
       and u.created_at < now() - interval '24 hours'
       and not exists (
           select 1 from public.devices d where d.auth_user_id = u.id
       );

    -- identities belonging only to devices revoked for more than 30 days
    delete from auth.users u
     where u.is_anonymous is true
       and u.id in (
           select d.auth_user_id
             from public.devices d
            where d.auth_user_id is not null
            group by d.auth_user_id
           having bool_and(d.revoked_at is not null)
              and max(d.revoked_at) < now() - interval '30 days'
       );
    $job$
);
