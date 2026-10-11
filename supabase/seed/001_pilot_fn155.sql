-- FarmaNorte · datos iniciales del piloto

insert into public.zones (name)
values ('Zona norte')
on conflict (name) do update set active = true;

insert into public.pharmacies (code, name, zone_name)
values ('155', 'FN 155', 'Zona norte')
on conflict (code) do update
set name = excluded.name,
    zone_name = excluded.zone_name,
    active = true;

insert into public.zone_pharmacies (zone_id, pharmacy_code)
select z.id, '155'
from public.zones z
where z.name = 'Zona norte'
on conflict (zone_id, pharmacy_code) do nothing;
