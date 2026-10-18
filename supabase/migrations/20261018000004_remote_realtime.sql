-- Realtime: publish only the minimum safe tables. Never drop/recreate the publication.
-- Forward-only migration.

do $$
begin
    if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        create publication supabase_realtime;
    end if;
end $$;

do $$
declare
    target text;
    targets text[] := array['account_settings', 'devices', 'device_status', 'device_commands'];
begin
    foreach target in array targets loop
        if not exists (
            select 1
              from pg_publication_tables
             where pubname = 'supabase_realtime'
               and schemaname = 'public'
               and tablename = target
        ) then
            execute format('alter publication supabase_realtime add table public.%I', target);
        end if;
    end loop;
end $$;
