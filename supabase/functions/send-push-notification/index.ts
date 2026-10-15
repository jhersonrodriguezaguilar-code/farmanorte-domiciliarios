import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SignJWT, importPKCS8 } from 'https://esm.sh/jose@5.10.0';
import * as webPush from 'npm:web-push@3.0.0';

type AdminClient = SupabaseClient<any, 'public', any>;

const corsHeaders = {
  'Access-Control-Allow-Origin': Deno.env.get('FARMANORTE_WEB_ORIGIN')
    ?? 'https://jhersonrodriguezaguilar-code.github.io',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};

const courierWebUrl = Deno.env.get('FARMANORTE_COURIER_WEB_URL')
  ?? 'https://jhersonrodriguezaguilar-code.github.io/farmanorte-pharmacy-web/courier/';

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

type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
};

type DeliveryRow = {
  id: string;
  public_code: string | null;
  pharmacy_code: string;
  zone_id: string | null;
  pickup_stops: unknown;
  destination_options: unknown;
  service_type: string | null;
  status: string;
  accepted_courier_id: string | null;
  // Migración 042: motivo cuando la farmacia cancela.
  cancellation_reason?: string | null;
  // Migración 039: hasta esta hora la oferta es solo para la zona.
  priority_until?: string | null;
};

type PushEvent =
  | 'delivery_created'
  | 'delivery_assigned'
  | 'delivery_support_release'
  | 'delivery_cancelled'
  | 'delivery_released'
  | 'chat_message';

// Quién recibe un domicilio nuevo (migración 041):
// - home: domiciliarios de zona de la farmacia que pide (reserva de 3 min).
// - release: las demás zonas del recorrido y los apoyos, al terminar la reserva.
// - all: todos los anteriores.
type CourierAudience = 'home' | 'release' | 'all';

const priorityActive = (delivery: DeliveryRow) =>
  Boolean(delivery.priority_until) &&
  new Date(String(delivery.priority_until)).getTime() > Date.now();

type PushTokenRow = {
  id: string;
  token: string;
  platform: 'android' | 'ios' | 'web';
  alert_sound?: string | null;
};

// Debe coincidir con courierAlertSoundOptions en lib/main.dart (APK 0.20.7+).
const knownAlertSounds = new Set([
  'fast_ping',
  'delivery_alert',
  'message_alert',
  'koiroylers_shop',
  'akshai_orders',
]);

type PushKind = 'delivery' | 'delivery_assigned' | 'chat_message';

// Canales v3 creados por la APK. Si el teléfono tiene una APK anterior y el
// canal no existe, Android usa el canal por defecto del AndroidManifest.
const androidChannelFor = (kind: PushKind, alertSound: string | null | undefined) => {
  if (kind === 'chat_message') return 'fn_chat_v3';
  const sound = alertSound && knownAlertSounds.has(alertSound) ? alertSound : 'fast_ping';
  return kind === 'delivery_assigned'
    ? `fn_assigned_${sound}_v3`
    : `fn_new_delivery_${sound}_v3`;
};

type PushSendResult = { sent: number; stale: number; failed: number };

const isDirectWebPushSubscription = (token: string) => {
  try {
    const parsed = JSON.parse(token) as {
      endpoint?: unknown;
      keys?: { auth?: unknown; p256dh?: unknown };
    };
    return typeof parsed.endpoint === 'string' &&
      typeof parsed.keys?.auth === 'string' &&
      typeof parsed.keys?.p256dh === 'string';
  } catch {
    return false;
  }
};

const deactivateStaleTokens = async (
  adminClient: AdminClient,
  tokenIds: string[],
) => {
  if (tokenIds.length === 0) return;
  const { error } = await adminClient
    .from('push_tokens')
    .update({ active: false, updated_at: new Date().toISOString() })
    .in('id', tokenIds);
  if (error) throw new Error(`No se pudieron desactivar tokens vencidos: ${error.message}`);
};

let cachedAccessToken: { value: string; expiresAt: number } | null = null;

const colombiaToday = () => {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Bogota',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
};

const serviceAccountFromEnvironment = (): ServiceAccount | null => {
  const raw = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON');
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<ServiceAccount>;
    if (!parsed.project_id || !parsed.client_email || !parsed.private_key) return null;
    return {
      project_id: parsed.project_id,
      client_email: parsed.client_email,
      private_key: parsed.private_key,
    };
  } catch {
    return null;
  }
};

const firebaseAccessToken = async (account: ServiceAccount) => {
  const now = Math.floor(Date.now() / 1000);
  if (cachedAccessToken && cachedAccessToken.expiresAt > now + 60) {
    return cachedAccessToken.value;
  }

  const privateKey = await importPKCS8(
    account.private_key.replace(/\\n/g, '\n'),
    'RS256',
  );
  const assertion = await new SignJWT({
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
  })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuer(account.client_email)
    .setAudience('https://oauth2.googleapis.com/token')
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(privateKey);

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!response.ok) {
    throw new Error(`No se pudo obtener el token de Firebase: ${response.status}`);
  }
  const token = await response.json() as { access_token?: string; expires_in?: number };
  if (!token.access_token) throw new Error('Firebase no devolvió un access_token.');
  cachedAccessToken = {
    value: token.access_token,
    expiresAt: now + Math.max(300, token.expires_in ?? 3600),
  };
  return token.access_token;
};

const deliveryColumns =
  'id, public_code, pharmacy_code, zone_id, pickup_stops, destination_options, service_type, status, accepted_courier_id';

const readDelivery = async (adminClient: AdminClient, deliveryId: string) => {
  const read = (columns: string) => adminClient
    .from('deliveries')
    .select(columns)
    .eq('id', deliveryId)
    .maybeSingle();
  // priority_until llega con la migración 039; sin ella se lee como antes.
  let result = await read(`${deliveryColumns}, priority_until, cancellation_reason`);
  if (result.error && /priority_until|cancellation_reason/.test(result.error.message)) {
    result = await read(deliveryColumns);
  }
  if (result.error) throw new Error(`No se pudo leer el domicilio: ${result.error.message}`);
  return result.data as unknown as DeliveryRow | null;
};

const deliveryRoutePharmacyCodes = (delivery: DeliveryRow) => {
  const codes = new Set<string>();
  const addCode = (value: unknown) => {
    if (typeof value === 'string' && value.trim()) codes.add(value.trim());
  };
  const addStops = (value: unknown) => {
    if (!Array.isArray(value)) return;
    for (const stop of value) {
      if (!stop || typeof stop !== 'object' || Array.isArray(stop)) continue;
      const row = stop as Record<string, unknown>;
      addCode(row.pharmacy_code);
      addCode(row.pickup_code);
      addCode(row.origin_pharmacy_code);
      addCode(row.originPharmacyCode);
      addCode(row.destination_pharmacy_code);
      addCode(row.destinationPharmacyCode);
      addCode(row.destination_code);
    }
  };

  addCode(delivery.pharmacy_code);
  addStops(delivery.pickup_stops);
  addStops(delivery.destination_options);
  return [...codes];
};

const eligibleCourierIds = async (
  adminClient: AdminClient,
  delivery: DeliveryRow,
  audience: CourierAudience = 'all',
) => {
  const pharmacyCodes = deliveryRoutePharmacyCodes(delivery);
  const routeZoneIds = new Set<string>();
  const homeZoneIds = new Set<string>();
  if (delivery.zone_id) {
    routeZoneIds.add(delivery.zone_id);
    homeZoneIds.add(delivery.zone_id);
  }

  if (pharmacyCodes.length > 0) {
    const { data: routePharmacies, error: routeError } = await adminClient
      .from('zone_pharmacies')
      .select('pharmacy_code, zone_id')
      .in('pharmacy_code', pharmacyCodes);
    if (routeError) throw new Error(`No se pudieron determinar las zonas del recorrido: ${routeError.message}`);
    for (const row of routePharmacies ?? []) {
      if (!row.zone_id) continue;
      routeZoneIds.add(String(row.zone_id));
      if (String(row.pharmacy_code).trim() === String(delivery.pharmacy_code).trim()) {
        homeZoneIds.add(String(row.zone_id));
      }
    }
  }

  const { data, error } = await adminClient
    .from('shifts')
    .select('courier_id, zone_id, assignment_type')
    .eq('scheduled_for', colombiaToday())
    .in('status', ['scheduled', 'active']);
  if (error) throw new Error(`No se pudieron leer los turnos: ${error.message}`);
  const courierIds = new Set<string>();
  for (const row of data ?? []) {
    const isSupport = row.assignment_type === 'support';
    const zoneId = row.zone_id ? String(row.zone_id) : '';
    // Apoyo general (sin zona) o apoyo de una zona del recorrido.
    const supportCovers = isSupport && (!zoneId || routeZoneIds.has(zoneId));
    const homeCovers = !isSupport && Boolean(zoneId) && homeZoneIds.has(zoneId);
    const otherRouteCovers = !isSupport && Boolean(zoneId) &&
      routeZoneIds.has(zoneId) && !homeZoneIds.has(zoneId);
    const include = audience === 'home'
      ? homeCovers
      : audience === 'release'
      ? otherRouteCovers || supportCovers
      : homeCovers || otherRouteCovers || supportCovers;
    if (include && row.courier_id) courierIds.add(String(row.courier_id));
  }
  if (courierIds.size === 0) return [];

  const { data: activeCouriers, error: profileError } = await adminClient
    .from('profiles')
    .select('id')
    .in('id', [...courierIds])
    .eq('role', 'courier')
    .eq('active', true);
  if (profileError) throw new Error(`No se pudieron validar los domiciliarios activos: ${profileError.message}`);
  return (activeCouriers ?? []).map((row) => String(row.id));
};

const targetUserIds = async ({
  adminClient,
  event,
  delivery,
  message,
  actorId,
}: {
  adminClient: AdminClient;
  event: PushEvent;
  delivery: DeliveryRow;
  message: Record<string, unknown> | null;
  actorId: string;
}) => {
  const targetIds = new Set<string>();

  if (event === 'delivery_created' || event === 'delivery_released') {
    const courierIds = await eligibleCourierIds(
      adminClient,
      delivery,
      priorityActive(delivery) ? 'home' : 'all',
    );
    courierIds.forEach((id) => targetIds.add(id));
  } else if (event === 'delivery_support_release') {
    const courierIds = await eligibleCourierIds(adminClient, delivery, 'release');
    courierIds.forEach((id) => targetIds.add(id));
  } else if (event === 'delivery_assigned' || event === 'delivery_cancelled') {
    if (delivery.accepted_courier_id) targetIds.add(delivery.accepted_courier_id);
  } else if (message?.sender_role === 'courier') {
    const { data, error } = await adminClient
      .from('profiles')
      .select('id')
      .eq('role', 'pharmacy')
      .eq('pharmacy_code', delivery.pharmacy_code)
      .eq('active', true);
    if (error) throw new Error(`No se pudo localizar la farmacia: ${error.message}`);
    for (const row of data ?? []) targetIds.add(String(row.id));
  } else if (delivery.accepted_courier_id) {
    targetIds.add(delivery.accepted_courier_id);
  } else {
    const courierIds = await eligibleCourierIds(adminClient, delivery);
    courierIds.forEach((id) => targetIds.add(id));
  }

  targetIds.delete(actorId);
  return [...targetIds];
};

const sendToTokens = async ({
  account,
  tokens,
  title,
  body,
  data,
  kind,
  courierLink,
  adminClient,
}: {
  account: ServiceAccount;
  tokens: Array<{
    id: string;
    token: string;
    platform: 'android' | 'ios' | 'web';
    alert_sound?: string | null;
  }>;
  title: string;
  body: string;
  data: Record<string, string>;
  kind: PushKind;
  courierLink: string;
  adminClient: AdminClient;
}) => {
  const accessToken = await firebaseAccessToken(account);
  const staleTokenIds: string[] = [];
  let sent = 0;
  let failed = 0;

  for (const tokenRow of tokens) {
    const response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token: tokenRow.token,
            notification: { title, body },
            data,
            android: {
              priority: 'HIGH',
              // Un domicilio vence rápido: si el teléfono no recibe el aviso en
              // 10 minutos ya no sirve entregarlo.
              ttl: '600s',
              notification: {
                channel_id: androidChannelFor(kind, tokenRow.alert_sound),
                icon: 'ic_notification',
                color: '#003399',
                // Una tarjeta por domicilio y tipo; el chat agrupa por mensaje.
                tag: kind === 'chat_message'
                  ? `chat-${data.message_id ?? data.delivery_id}`
                  : `${kind}-${data.delivery_id}`,
                // Sin click_action: Android abre la actividad principal y
                // FlutterFire entrega el toque a getInitialMessage /
                // onMessageOpenedApp. Así funciona también en APK anteriores
                // que no declaraban el filtro FLUTTER_NOTIFICATION_CLICK.
              },
            },
            apns: {
              headers: { 'apns-priority': '10' },
              payload: { aps: { sound: 'default', badge: 1 } },
            },
            ...(tokenRow.platform === 'web'
              ? {
                webpush: {
                  notification: { title, body },
                  fcm_options: { link: courierLink },
                },
              }
              : {}),
          },
        }),
      },
    );
    const responseText = await response.text();
    if (response.ok) {
      sent += 1;
    } else if (/UNREGISTERED|registration-token-not-registered/i.test(responseText)) {
      staleTokenIds.push(tokenRow.id);
    } else {
      failed += 1;
    }
  }

  await deactivateStaleTokens(adminClient, staleTokenIds);
  return { sent, stale: staleTokenIds.length, failed };
};

const sendToWebTokens = async ({
  tokens,
  title,
  body,
  data,
  adminClient,
}: {
  tokens: Array<{ id: string; token: string }>;
  title: string;
  body: string;
  data: Record<string, string>;
  adminClient: AdminClient;
}) => {
  const publicKey = Deno.env.get('WEB_PUSH_VAPID_PUBLIC_KEY');
  const privateKey = Deno.env.get('WEB_PUSH_VAPID_PRIVATE_KEY');
  const subject = Deno.env.get('WEB_PUSH_VAPID_SUBJECT') ??
    'https://jhersonrodriguezaguilar-code.github.io/farmanorte-pharmacy-web/';
  if (!publicKey || !privateKey) {
    return {
      sent: 0,
      stale: 0,
      failed: 0,
      skipped: tokens.length,
      reason: 'vapid_not_configured',
    };
  }

  webPush.setVapidDetails(subject, publicKey, privateKey);
  const staleTokenIds: string[] = [];
  let sent = 0;
  let failed = 0;
  for (const tokenRow of tokens) {
    try {
      await webPush.sendNotification(
        JSON.parse(tokenRow.token),
        JSON.stringify({ title, body, data }),
      );
      sent += 1;
    } catch (error) {
      const statusCode = typeof error === 'object' && error !== null && 'statusCode' in error
        ? Number((error as { statusCode?: unknown }).statusCode)
        : 0;
      if (statusCode === 404 || statusCode === 410) {
        staleTokenIds.push(tokenRow.id);
      } else {
        failed += 1;
      }
    }
  }

  await deactivateStaleTokens(adminClient, staleTokenIds);
  return { sent, stale: staleTokenIds.length, failed, skipped: 0, reason: null };
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
    return json({ error: 'Configuración segura de Supabase incompleta.' }, 500);
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
    .select('id, full_name, role, pharmacy_code, active')
    .eq('id', authData.user.id)
    .maybeSingle();
  if (actorError || !actor || actor.active !== true) {
    return json({ error: 'El perfil operativo no está activo.' }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'El cuerpo de la solicitud no es válido.' }, 400);
  }

  const knownEvents: PushEvent[] = [
    'chat_message',
    'delivery_assigned',
    'delivery_support_release',
    'delivery_cancelled',
    'delivery_released',
  ];
  const event: PushEvent = knownEvents.includes(body.event as PushEvent)
    ? body.event as PushEvent
    : 'delivery_created';
  const deliveryId = String(body.delivery_id ?? '').trim();
  if (!deliveryId) return json({ error: 'Falta delivery_id.' }, 400);

  const delivery = await readDelivery(adminClient, deliveryId);
  if (!delivery) return json({ error: 'El domicilio no existe.' }, 404);

  let message: Record<string, unknown> | null = null;
  if (event === 'delivery_created') {
    const allowed = actor.role === 'admin' ||
      (actor.role === 'pharmacy' && actor.pharmacy_code === delivery.pharmacy_code);
    if (!allowed) return json({ error: 'No puedes notificar este domicilio.' }, 403);
    if (delivery.status !== 'offered') return json({ ok: true, sent: 0, skipped: 'not_offered' });
    if (!priorityActive(delivery)) {
      // Sin reserva de zona el primer aviso ya incluye a los apoyos.
      await adminClient
        .from('deliveries')
        .update({ support_notified_at: new Date().toISOString() })
        .eq('id', delivery.id)
        .is('support_notified_at', null);
    }
  } else if (event === 'delivery_cancelled') {
    const allowed = actor.role === 'admin' ||
      (actor.role === 'pharmacy' && actor.pharmacy_code === delivery.pharmacy_code);
    if (!allowed) return json({ error: 'No puedes notificar esta cancelación.' }, 403);
    if (delivery.status !== 'cancelled') return json({ ok: true, sent: 0, skipped: 'not_cancelled' });
    if (!delivery.accepted_courier_id) return json({ ok: true, sent: 0, skipped: 'without_courier' });
  } else if (event === 'delivery_released') {
    // Solo quien liberó el domicilio (registrado en delivery_events) puede
    // pedir que se vuelva a ofrecer.
    if (actor.role !== 'courier' && actor.role !== 'admin') {
      return json({ error: 'No puedes notificar esta liberación.' }, 403);
    }
    if (delivery.status !== 'offered' || delivery.accepted_courier_id) {
      return json({ ok: true, sent: 0, skipped: 'not_offered' });
    }
    if (actor.role === 'courier') {
      const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
      const { data: releaseRows, error: releaseError } = await adminClient
        .from('delivery_events')
        .select('id')
        .eq('delivery_id', delivery.id)
        .eq('actor_id', authData.user.id)
        .eq('event_type', 'released')
        .gte('created_at', since)
        .limit(1);
      if (releaseError) return json({ error: `No se pudo validar la liberación: ${releaseError.message}` }, 500);
      if (!releaseRows || releaseRows.length === 0) {
        return json({ error: 'No liberaste este domicilio recientemente.' }, 403);
      }
    }
    if (!priorityActive(delivery)) {
      await adminClient
        .from('deliveries')
        .update({ support_notified_at: new Date().toISOString() })
        .eq('id', delivery.id)
        .is('support_notified_at', null);
    }
  } else if (event === 'delivery_support_release') {
    const allowed = actor.role === 'admin' ||
      (actor.role === 'pharmacy' && actor.pharmacy_code === delivery.pharmacy_code);
    if (!allowed) return json({ error: 'No puedes notificar este domicilio.' }, 403);
    if (delivery.status !== 'offered' || delivery.accepted_courier_id) {
      return json({ ok: true, sent: 0, skipped: 'not_offered' });
    }
    if (priorityActive(delivery)) {
      return json({ ok: true, sent: 0, skipped: 'zone_priority_active' });
    }
    // Solo la primera solicitud envía el aviso a los apoyos.
    const { data: claimed, error: claimError } = await adminClient
      .from('deliveries')
      .update({ support_notified_at: new Date().toISOString() })
      .eq('id', delivery.id)
      .is('support_notified_at', null)
      .select('id');
    if (claimError) return json({ error: `No se pudo registrar el aviso: ${claimError.message}` }, 500);
    if (!claimed || claimed.length === 0) {
      return json({ ok: true, sent: 0, skipped: 'already_notified' });
    }
  } else if (event === 'delivery_assigned') {
    const allowed = actor.role === 'admin' ||
      (actor.role === 'pharmacy' && actor.pharmacy_code === delivery.pharmacy_code);
    if (!allowed) return json({ error: 'No puedes notificar esta asignación.' }, 403);
    if (!delivery.accepted_courier_id) {
      return json({ ok: true, sent: 0, skipped: 'without_assigned_courier' });
    }
  } else {
    const messageId = String(body.message_id ?? '').trim();
    if (!messageId) return json({ error: 'Falta message_id.' }, 400);
    const { data: messageRow, error: messageError } = await adminClient
      .from('delivery_chat_messages')
      .select('id, sender_id, sender_name, sender_role, body')
      .eq('id', messageId)
      .eq('delivery_id', deliveryId)
      .maybeSingle();
    if (messageError || !messageRow) return json({ error: 'El mensaje no existe.' }, 404);
    if (messageRow.sender_id !== authData.user.id) {
      return json({ error: 'Solo el autor puede disparar esta notificación.' }, 403);
    }
    if (messageRow.sender_role !== actor.role) {
      return json({ error: 'El rol del mensaje no coincide con el perfil autenticado.' }, 403);
    }
    const isDeliveryPharmacy = actor.role === 'pharmacy' &&
      actor.pharmacy_code === delivery.pharmacy_code;
    const isAssignedCourier = actor.role === 'courier' &&
      delivery.accepted_courier_id === authData.user.id;
    if (!isDeliveryPharmacy && !isAssignedCourier) {
      return json({ error: 'No perteneces a este chat de domicilio.' }, 403);
    }
    message = messageRow as Record<string, unknown>;
  }

  const recipientIds = await targetUserIds({
    adminClient,
    event,
    delivery,
    message,
    actorId: authData.user.id,
  });
  if (recipientIds.length === 0) return json({ ok: true, sent: 0, skipped: 'no_recipients' });

  // `alert_sound` llega con la migración 038; si aún no existe se reintenta
  // sin esa columna para no romper el envío.
  const readTokens = (columns: string) => adminClient
    .from('push_tokens')
    .select(columns)
    .in('user_id', recipientIds)
    .eq('active', true);
  let tokenResult = await readTokens('id, token, platform, alert_sound');
  if (tokenResult.error && /alert_sound/.test(tokenResult.error.message)) {
    tokenResult = await readTokens('id, token, platform');
  }
  const tokenRows = tokenResult.data as unknown as PushTokenRow[] | null;
  const tokenError = tokenResult.error;
  if (tokenError) return json({ error: `No se pudieron leer los dispositivos: ${tokenError.message}` }, 500);
  if (!tokenRows || tokenRows.length === 0) return json({ ok: true, sent: 0, skipped: 'no_active_devices' });

  const isChat = event === 'chat_message';
  const isAssignment = event === 'delivery_assigned';
  const isSupportRelease = event === 'delivery_support_release';
  const isCancelled = event === 'delivery_cancelled';
  const isReleased = event === 'delivery_released';
  const title = isChat
    ? 'Nuevo mensaje en el domicilio'
    : isAssignment
      ? 'Nuevo domicilio asignado'
      : isCancelled
        ? 'Domicilio cancelado'
        : isReleased
          ? 'Domicilio disponible de nuevo'
          : isSupportRelease
            ? 'Domicilio disponible para ti'
            : 'Nuevo domicilio disponible';
  const compactCode = (delivery.public_code ?? '').replace(/[\s_-]+/g, '').toUpperCase();
  const pharmacyLabel = `farmanorte ${delivery.pharmacy_code}`;
  const codeLabel = [compactCode, pharmacyLabel].filter(Boolean).join(' · ');
  const rawBody = isChat
    ? `${String(message?.sender_name ?? '').trim() || 'Operación'}: ${String(message?.body ?? 'Te escribieron en el chat.')}`
    : isCancelled
      ? `${codeLabel} · La farmacia lo canceló${delivery.cancellation_reason ? `: ${delivery.cancellation_reason}` : '.'} No lo recojas.`
    : isAssignment
      ? `${codeLabel} · La farmacia te asignó este domicilio. Toca para verlo.`
    : `${codeLabel}${delivery.service_type ? ` · ${delivery.service_type}` : ''} · Toca para ver y aceptar.`;
  const notificationBody = rawBody.length > 140 ? `${rawBody.slice(0, 137)}…` : rawBody;
  const pushKind: PushKind = isChat
    ? 'chat_message'
    : isAssignment || isCancelled
      ? 'delivery_assigned'
      : 'delivery';
  const pushData: Record<string, string> = {
    type: pushKind,
    delivery_id: delivery.id,
    message_id: isChat ? String(message?.id ?? '') : '',
    pharmacy_code: delivery.pharmacy_code ?? '',
    public_code: delivery.public_code ?? '',
    open_chat: isChat ? 'true' : 'false',
    sender_name: isChat ? String(message?.sender_name ?? actor.full_name ?? '') : '',
  };
  const typedTokenRows = (tokenRows ?? []) as PushTokenRow[];
  const fcmTokens = typedTokenRows
    .filter((row) => row.platform !== 'web' || !isDirectWebPushSubscription(row.token))
    .map(({ id, token, platform, alert_sound }) => ({ id, token, platform, alert_sound }));
  const webTokens = typedTokenRows
    .filter((row) => row.platform === 'web' && isDirectWebPushSubscription(row.token))
    .map(({ id, token }) => ({ id, token }));

  const account = serviceAccountFromEnvironment();
  if (fcmTokens.length > 0 && !account) {
    return json({
      error: 'FIREBASE_SERVICE_ACCOUNT_JSON falta o no tiene un formato válido en Supabase.',
      sent: 0,
      skipped: fcmTokens.length,
    }, 503);
  }

  const courierLinkUrl = new URL(courierWebUrl);
  courierLinkUrl.searchParams.set('delivery', delivery.id);
  if (isChat) courierLinkUrl.searchParams.set('chat', '1');
  const courierLink = courierLinkUrl.toString();

  let fcmResult: PushSendResult = { sent: 0, stale: 0, failed: 0 };
  if (account && fcmTokens.length > 0) {
    try {
      fcmResult = await sendToTokens({
        account,
        tokens: fcmTokens,
        title,
        body: notificationBody,
        data: pushData,
        kind: pushKind,
        courierLink,
        adminClient,
      });
    } catch (error) {
      console.error('No se pudieron enviar las notificaciones FCM.', error);
      fcmResult = { sent: 0, stale: 0, failed: fcmTokens.length };
    }
  }

  let webResult = {
    sent: 0,
    stale: 0,
    failed: 0,
    skipped: 0,
    reason: null as string | null,
  };
  if (webTokens.length > 0) {
    try {
      webResult = await sendToWebTokens({
        tokens: webTokens,
        title,
        body: notificationBody,
        data: pushData,
        adminClient,
      });
    } catch (error) {
      console.error('No se pudieron enviar las notificaciones Web Push.', error);
      webResult = {
        sent: 0,
        stale: 0,
        failed: webTokens.length,
        skipped: 0,
        reason: 'web_push_send_failed',
      };
    }
  }

  const sent = fcmResult.sent + webResult.sent;
  const stale = fcmResult.stale + webResult.stale;
  const failed = fcmResult.failed + webResult.failed;
  if (webResult.reason === 'vapid_not_configured') {
    return json({
      error: 'Faltan las claves VAPID en los secretos de Supabase.',
      sent,
      failed,
      stale,
      web_skipped: webResult.skipped,
    }, 503);
  }
  if (failed > 0) {
    return json({
      error: 'Algunas notificaciones no se pudieron enviar.',
      sent,
      failed,
      stale,
      web_skipped: webResult.skipped,
      web_reason: webResult.reason,
    }, 502);
  }

  return json({
    ok: true,
    recipients: recipientIds.length,
    sent,
    failed,
    stale,
    web_skipped: webResult.skipped,
    web_reason: webResult.reason,
  });
});
