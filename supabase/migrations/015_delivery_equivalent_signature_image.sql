-- Firma manuscrita del domiciliario para el equivalente digital.
alter table public.delivery_equivalents
  add column if not exists courier_signature_image text;

create or replace function public.sign_delivery_equivalent_with_image(
  requested_equivalent_id uuid,
  requested_signature_name text,
  requested_signature_image text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if coalesce(length(btrim(requested_signature_image)), 0) < 100
     or left(btrim(requested_signature_image), 22) <> 'data:image/png;base64,' then
    raise exception 'La firma manuscrita no es válida.';
  end if;

  if length(requested_signature_image) > 1500000 then
    raise exception 'La imagen de la firma es demasiado grande.';
  end if;

  update public.delivery_equivalents
  set courier_signature_name = coalesce(
        nullif(btrim(requested_signature_name), ''),
        'Firma manuscrita'
      ),
      courier_signature_image = btrim(requested_signature_image),
      courier_signed_at = now(),
      status = 'signed',
      updated_at = now()
  where id = requested_equivalent_id
    and courier_id = auth.uid()
    and status = 'draft';

  if not found then
    raise exception 'El equivalente no existe, ya fue firmado o no pertenece al domiciliario.';
  end if;
  return true;
end;
$fn$;

grant execute on function public.sign_delivery_equivalent_with_image(uuid, text, text)
  to authenticated;
