-- Privilegios mínimos para el Edge Function administrativo.
-- El rol service_role conserva bypassrls, pero este proyecto no tenía
-- permisos de tabla explícitos sobre profiles.
grant select, insert, update, delete
on table public.profiles
to service_role;
