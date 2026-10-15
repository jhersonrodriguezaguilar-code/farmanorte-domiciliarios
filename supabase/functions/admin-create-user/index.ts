import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

type AdminClient = SupabaseClient<any, 'public', any>;

const corsHeaders = {
  'Access-Control-Allow-Origin': Deno.env.get('FARMANORTE_WEB_ORIGIN')
    ?? 'https://jhersonrodriguezaguilar-code.github.io',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

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

type PharmacyProfileInput = {
  id?: string;
  display_name: string;
  username: string;
  profile_role: 'vendedor' | 'cajero';
  active: boolean;
};

const normalizePharmacyProfiles = (value: unknown, fallbackName: string): PharmacyProfileInput[] => {
  const rows = Array.isArray(value) ? value : [];
  const profiles = rows.map((row) => {
    const item = (row && typeof row === 'object') ? row as Record<string, unknown> : {};
    const displayName = String(item.display_name ?? item.name ?? '').trim();
    const username = String(item.username ?? '').trim();
    const profileRole = item.profile_role === 'cajero' ? 'cajero' : 'vendedor';
    return {
      display_name: displayName,
      username,
      profile_role: profileRole,
      active: item.active !== false,
    } satisfies PharmacyProfileInput;
  }).filter((profile) => profile.display_name);

  if (profiles.length > 0) return profiles;
  return [{
    display_name: fallbackName,
    username: '',
    profile_role: 'vendedor',
    active: true,
  }];
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

const assignUniqueProfileUsernames = async (
  adminClient: AdminClient,
  pharmacyCode: string,
  profiles: PharmacyProfileInput[],
) => {
  const { data: existingRows, error } = await adminClient
    .from('pharmacy_profiles')
    .select('username')
    .eq('pharmacy_code', pharmacyCode);
  if (error) return { profiles: null, error };

  const used = new Set<string>(
    (existingRows ?? [])
      .map((row) => String(row.username ?? '').trim().toLowerCase())
      .filter(Boolean),
  );
  return {
    profiles: profiles.map((profile) => ({
      ...profile,
      username: uniqueProfileUsername(
        profile.username,
        pharmacyCode,
        profile.display_name,
        used,
      ),
    })),
    error: null,
  };
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
  const normalizedPhone = phone?.replace(/\D/g, '') ?? '';
  if (role !== 'pharmacy' && !/^3\d{9}$/.test(normalizedPhone)) {
    return json({ error: 'El teléfono debe empezar por 3 y tener exactamente 10 números.' }, 400);
  }

  let pharmacyProfiles: PharmacyProfileInput[] = [];
  if (role === 'pharmacy') {
    const requiredPharmacyCode = pharmacyCode;
    if (!requiredPharmacyCode) {
      return json({ error: 'Un usuario de farmacia necesita farmacia asignada.' }, 400);
    }
    const { data: existingPharmacyAccount, error: existingAccountError } = await adminClient
      .from('profiles')
      .select('id')
      .eq('role', 'pharmacy')
      .eq('pharmacy_code', requiredPharmacyCode)
      .eq('active', true)
      .maybeSingle();
    if (existingAccountError) {
      return json({ error: `No se pudo validar la cuenta de farmacia: ${existingAccountError.message}` }, 500);
    }
    if (existingPharmacyAccount) {
      return json({ error: `La farmacia ${requiredPharmacyCode} ya tiene una cuenta activa. Edítala para agregar o desactivar perfiles.` }, 409);
    }
    const inputProfiles = normalizePharmacyProfiles(body.subprofiles, fullName);
    const assigned = await assignUniqueProfileUsernames(
      adminClient,
      requiredPharmacyCode,
      inputProfiles,
    );
    if (assigned.error || !assigned.profiles) {
      return json({ error: `No se pudieron preparar los perfiles de farmacia: ${assigned.error?.message ?? 'error desconocido'}` }, 500);
    }
    pharmacyProfiles = assigned.profiles;
    const profileUsernames = new Set<string>();
    for (const profile of pharmacyProfiles) {
      if (!usernamePattern.test(profile.username)) {
        return json({ error: `El usuario del perfil "${profile.display_name}" no es válido.` }, 400);
      }
      if (profileUsernames.has(profile.username)) {
        return json({ error: 'Los usuarios de los perfiles deben ser diferentes.' }, 400);
      }
      profileUsernames.add(profile.username);
    }
  }

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
    phone: normalizedPhone || null,
    active: true,
    must_change_password: true,
  });
  if (profileError) {
    await adminClient.auth.admin.deleteUser(created.user.id);
    return json({ error: `No se pudo crear el perfil: ${profileError.message}` }, 400);
  }

  let createdPharmacyProfiles: Record<string, unknown>[] = [];
  if (role === 'pharmacy') {
    const { data: insertedProfiles, error: pharmacyProfilesError } = await adminClient
      .from('pharmacy_profiles')
      .insert(pharmacyProfiles.map((profile) => ({
        pharmacy_code: pharmacyCode,
        display_name: profile.display_name,
        username: profile.username,
        profile_role: profile.profile_role,
        active: profile.active,
        created_by: authData.user.id,
      })))
      .select('id, pharmacy_code, display_name, username, profile_role, active');
    if (pharmacyProfilesError) {
      await adminClient.from('profiles').delete().eq('id', created.user.id);
      await adminClient.auth.admin.deleteUser(created.user.id);
      return json({ error: `No se pudieron crear los perfiles de farmacia: ${pharmacyProfilesError.message}` }, 400);
    }
    createdPharmacyProfiles = (insertedProfiles ?? []) as Record<string, unknown>[];
  }

  const { error: auditError } = await adminClient.from('admin_audit_log').insert({
    actor_id: authData.user.id,
    action: 'user_created',
    target_user_id: created.user.id,
    target_table: 'profiles',
    metadata: { role, pharmacy_code: pharmacyCode, profile_count: createdPharmacyProfiles.length },
  });
  if (auditError) console.warn('No se pudo escribir la bitácora de creación:', auditError.message);

  return json({
    user: {
      id: created.user.id,
      username,
      email: technicalEmail,
      full_name: fullName,
      role,
      pharmacy_code: pharmacyCode,
      active: true,
      must_change_password: true,
    },
    pharmacy_profiles: createdPharmacyProfiles,
    // Se entrega una sola vez al administrador que acaba de crear la cuenta;
    // nunca se guarda en texto plano en perfiles ni en metadatos públicos.
    temporary_password: password,
  }, 201);
});
