-- FarmaNorte · Etapa 2 · campos operativos del panel administrativo
-- Ejecutar después de 001_initial_schema.sql.

alter table public.pharmacies
  add column if not exists address text not null default '',
  add column if not exists latitude double precision,
  add column if not exists longitude double precision;

alter table public.zones
  add column if not exists reference text not null default '';
