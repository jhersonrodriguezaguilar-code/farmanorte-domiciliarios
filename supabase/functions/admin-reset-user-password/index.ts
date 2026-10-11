import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

const defaultKeyFromDictionary = (name: string) => {
  const raw = Deno.env.get(name);
  if (!raw) return null;
  try {
    const dictionary = JSON.parse(raw) as Record<string, unknown>;
    const value = dictionary.default ?? Object.values(dictionary)[0];
    return typeof value === 'string' ? value : null;
  } catch {
    return null;
  }
};

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = defaultKeyFromDictionary('SUPABASE_PUBLISHABLE_KEYS')
    ?? Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = defaultKeyFromDictionary('SUPABASE_SECRET_KEYS')
    ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const authorization = request.headers.get('Authorization');
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: 'Configuración segura incompleta.' }, 500);
  }
  if (!authorization) return json({ error: 'Sesión no válida.' }, 401);

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
  });
  const adminClient = createClient(supabaseUrl, serviceRoleKey);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return json({ error: 'Sesión no válida.' }, 401);

  const { data: actor, error: actorError } = await adminClient
    .from('profiles')
    .select('role, active')
    .eq('id', authData.user.id)
    .maybeSingle();
  if (actorError) return json({ error: 'No se pudo validar el administrador.' }, 500);
  if (actor?.role !== 'admin' || actor.active !== true) {
    return json({ error: 'Solo un administrador activo puede cambiar contraseñas.' }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'El cuerpo de la solicitud no es válido.' }, 400);
  }

  const userId = String(body.user_id ?? '').trim();
  const password = String(body.password ?? '');
  if (!userId || password.length < 8) {
    return json({ error: 'Usuario y contraseña de mínimo 8 caracteres son obligatorios.' }, 400);
  }

  const { data: target, error: targetError } = await adminClient
    .from('profiles')
    .select('id')
    .eq('id', userId)
    .maybeSingle();
  if (targetError) return json({ error: 'No se pudo validar el perfil destino.' }, 500);
  if (!target) return json({ error: 'El perfil destino no existe.' }, 404);

  const { error: updateError } = await adminClient.auth.admin.updateUserById(
    userId,
    { password },
  );
  if (updateError) {
    return json({ error: `No se pudo actualizar la contraseña: ${updateError.message}` }, 400);
  }

  return json({ ok: true });
});
