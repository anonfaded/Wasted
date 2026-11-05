-- A consumed enrollment token cannot survive its device: setting only
-- consumed_by_device_id to null violates device_enrollments_consumed_pair.
-- Removing the device must remove its enrollment audit row instead.

alter table private.device_enrollments
    drop constraint device_enrollments_consumed_by_device_id_fkey;

alter table private.device_enrollments
    add constraint device_enrollments_consumed_by_device_id_fkey
    foreign key (consumed_by_device_id) references public.devices (id) on delete cascade;
