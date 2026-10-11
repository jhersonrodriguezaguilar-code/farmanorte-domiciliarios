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

const usernamePattern = /^[a-z0-9][a-z0-9._-]{2,38}[a-z0-9]$/;

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
  if (actorError) {
    console.error('admin actor lookup failed', {
      userId: authData.user.id,
      code: actorError.code,
      message: actorError.message,
    });
    return json({ error: 'No se pudo validar el administrador.' }, 500);
  }
  if (actor?.role !== 'admin' || actor.active !== true) {
    console.warn('admin actor is not active', {
      userId: authData.user.id,
      role: actor?.role ?? null,
      active: actor?.active ?? null,
    });
    return json({ error: 'Solo un administrador activo puede crear usuarios.' }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'El cuerpo de la solicitud no es válido.' }, 400);
  }

  const username = String(body.username ?? '').trim().toLowerCase();
  const fullName = String(body.full_name ?? '').trim();
  const role = String(body.role ?? '').trim();
  const pharmacyCode = body.pharmacy_code ? String(body.pharmacy_code).trim() : null;
  const phone = body.phone ? String(body.phone).trim() : null;
  const password = String(body.password ?? '');

  if (!usernamePattern.test(username)) {
    return json({ error: 'El usuario debe tener entre 4 y 40 caracteres: letras, números, punto, guion o guion bajo.' }, 400);
  }
  if (!fullName || !['admin', 'pharmacy', 'courier'].includes(role)) {
    return json({ error: 'Nombre y rol son obligatorios.' }, 400);
  }
  if (password.length < 8) return json({ error: 'La contraseña inicial debe tener mínimo 8 caracteres.' }, 400);
  if (role === 'pharmacy' && !pharmacyCode) return json({ error: 'Un usuario de farmacia necesita farmacia asignada.' }, 400);

  const technicalEmail = `${username}@farmanorte.local`;
  const { data: created, error: createError } = await adminClient.auth.admin.createUser({
    email: technicalEmail,
    password,
    email_confirm: true,
    user_metadata: { username, created_by_admin: authData.user.id },
  });
  if (createError || !created.user) return json({ error: createError?.message ?? 'No se pudo crear el usuario Auth.' }, 400);

  const { error: profileError } = await adminClient.from('profiles').insert({
    id: created.user.id,
    username,
    full_name: fullName,
    role,
    pharmacy_code: pharmacyCode,
    phone,
    active: true,
  });
  if (profileError) {
    await adminClient.auth.admin.deleteUser(created.user.id);
    return json({ error: `No se pudo crear el perfil: ${profileError.message}` }, 400);
  }

  return json({
    user: {
      id: created.user.id,
      username,
      email: technicalEmail,
      full_name: fullName,
      role,
      pharmacy_code: pharmacyCode,
      active: true,
    },
  }, 201);
});
