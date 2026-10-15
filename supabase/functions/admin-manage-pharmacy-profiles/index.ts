import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': Deno.env.get('FARMANORTE_WEB_ORIGIN')
    ?? 'https://jhersonrodriguezaguilar-code.github.io',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};

const json = (body: Record<string, unknown>, status = 200) => new Response(
  JSON.stringify(body),
  { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
);

const usernamePattern = /^[a-z0-9][a-z0-9._-]{2,38}[a-z0-9]$/;

const normalizeProfileUsername = (value: unknown, fallback: string) => {
  const source = String(value ?? '').trim().toLowerCase() || fallback.trim().toLowerCase();
  const normalized = source
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9._-]+/g, '.')
    .replace(/^[._-]+|[._-]+$/g, '')
    .slice(0, 40)
    .replace(/[._-]+$/g, '');
  if (usernamePattern.test(normalized)) return normalized;
  const compactFallback = fallback
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '')
    .slice(0, 34);
  const candidate = compactFallback.length >= 3 ? compactFallback + '1' : 'perfil1';
  return usernamePattern.test(candidate) ? candidate : 'perfil1';
};

const uniqueProfileUsername = (
  requested: string,
  pharmacyCode: string,
  displayName: string,
  used: Set<string>,
) => {
  const fallback = `fn${pharmacyCode}.perfil.${displayName}`;
  const base = normalizeProfileUsername(requested, fallback);
  let candidate = base;
  var suffix = 2;
  while (used.has(candidate.toLowerCase())) {
    const ending = `-${suffix}`;
    candidate = `${base.slice(0, 40 - ending.length)}${ending}`;
    suffix += 1;
  }
  used.add(candidate.toLowerCase());
  return candidate;
};

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

const isRecord = (value: unknown): value is Record<string, unknown> =>
  Boolean(value && typeof value === 'object' && !Array.isArray(value));

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json({ error: 'Método no permitido.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = defaultKeyFromDictionary('SUPABASE_PUBLISHABLE_KEYS') ?? Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = defaultKeyFromDictionary('SUPABASE_SECRET_KEYS') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const authorization = request.headers.get('Authorization');
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json({ error: 'Configuración segura incompleta.' }, 500);
  if (!authorization) return json({ error: 'Sesión no válida.' }, 401);

  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } });
  const adminClient = createClient(supabaseUrl, serviceRoleKey);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return json({ error: 'Sesión no válida.' }, 401);

  const { data: actor, error: actorError } = await adminClient
    .from('profiles')
    .select('role, active')
    .eq('id', authData.user.id)
    .maybeSingle();
  if (actorError) return json({ error: 'No se pudo validar el administrador.' }, 500);
  if (actor?.role !== 'admin' || actor.active !== true) return json({ error: 'Solo un administrador activo puede gestionar perfiles de farmacia.' }, 403);

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'El cuerpo de la solicitud no es válido.' }, 400);
  }

  const pharmacyCode = String(body.pharmacy_code ?? '').trim();
  const inputRows = Array.isArray(body.profiles) ? body.profiles : [];
  if (!pharmacyCode || inputRows.length === 0) return json({ error: 'Farmacia y al menos un perfil son obligatorios.' }, 400);

  const normalized = inputRows.map((row) => {
    const item = isRecord(row) ? row : {};
    return {
      id: item.id ? String(item.id).trim() : null,
      display_name: String(item.display_name ?? '').trim(),
      username: String(item.username ?? '').trim(),
      profile_role: item.profile_role === 'cajero' ? 'cajero' : 'vendedor',
      active: item.active !== false,
    };
  });
  for (const profile of normalized) {
    if (!profile.display_name) return json({ error: 'Cada perfil necesita un nombre.' }, 400);
  }

  const { data: pharmacyAccount, error: accountError } = await adminClient
    .from('profiles')
    .select('id')
    .eq('role', 'pharmacy')
    .eq('pharmacy_code', pharmacyCode)
    .maybeSingle();
  if (accountError) return json({ error: `No se pudo validar la cuenta de ${pharmacyCode}: ${accountError.message}` }, 500);
  if (!pharmacyAccount) return json({ error: `No existe una cuenta de farmacia para ${pharmacyCode}.` }, 404);

  const { data: existingRows, error: existingError } = await adminClient
    .from('pharmacy_profiles')
    .select('id, username')
    .eq('pharmacy_code', pharmacyCode);
  if (existingError) return json({ error: `No se pudieron validar los perfiles existentes: ${existingError.message}` }, 500);

  const existingById = new Map<string, string>();
  const used = new Set<string>();
  for (const row of existingRows ?? []) {
    const id = String(row.id ?? '').trim();
    const username = String(row.username ?? '').trim().toLowerCase();
    if (id && username) existingById.set(id, username);
    if (username) used.add(username);
  }

  const prepared = normalized.map((profile) => {
    const currentUsername = profile.id ? existingById.get(profile.id) : null;
    if (currentUsername) used.delete(currentUsername);
    return {
      ...profile,
      username: uniqueProfileUsername(
        currentUsername ?? profile.username,
        pharmacyCode,
        profile.display_name,
        used,
      ),
    };
  });

  for (const profile of prepared) {
    const payload = {
      pharmacy_code: pharmacyCode,
      display_name: profile.display_name,
      username: profile.username,
      profile_role: profile.profile_role,
      active: profile.active,
      updated_at: new Date().toISOString(),
    };
    const operation = profile.id
      ? adminClient.from('pharmacy_profiles').update(payload).eq('id', profile.id).eq('pharmacy_code', pharmacyCode)
      : adminClient.from('pharmacy_profiles').insert({ ...payload, created_by: authData.user.id });
    const { error: profileError } = await operation;
    if (profileError) return json({ error: `No se pudo guardar el perfil ${profile.display_name}: ${profileError.message}` }, 400);
  }

  const { data: savedProfiles, error: savedError } = await adminClient
    .from('pharmacy_profiles')
    .select('id, pharmacy_code, display_name, username, profile_role, active')
    .eq('pharmacy_code', pharmacyCode)
    .order('display_name');
  if (savedError) return json({ error: `No se pudieron leer los perfiles guardados: ${savedError.message}` }, 500);
  const { error: auditError } = await adminClient.from('admin_audit_log').insert({
    actor_id: authData.user.id,
    action: 'pharmacy_profiles_updated',
    target_table: 'pharmacy_profiles',
    metadata: { pharmacy_code: pharmacyCode, profile_count: savedProfiles?.length ?? 0 },
  });
  if (auditError) console.warn('No se pudo escribir la bitácora de perfiles:', auditError.message);
  return json({ profiles: savedProfiles ?? [] });
});
