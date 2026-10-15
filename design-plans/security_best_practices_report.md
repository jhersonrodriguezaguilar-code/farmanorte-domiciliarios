# Informe de seguridad — FarmaNorte

Fecha: 2026-10-12  
Alcance: JavaScript/React de la página de farmacia, Dart/Flutter, funciones
Supabase Edge y migraciones SQL.

## Resumen

Hay controles importantes bien encaminados: las tablas sensibles tienen RLS,
las funciones Edge validan el JWT y el perfil activo, la clave service_role se
usa en servidor y no aparece en la página web, los mensajes de chat fijan el
remitente desde auth.uid(), y npm audit --omit=dev no reportó vulnerabilidades.

Se encontraron cuatro riesgos que deben resolverse antes de una entrega real y
tres medidas de endurecimiento/documentación. Los dos más urgentes son la
firma debug de la APK y la posibilidad de que un cliente autenticado modifique
campos sensibles de un domicilio mediante un update directo.

## Hallazgos

### FN-SEC-001 — La variante release se firma con la clave debug

- Severidad: alta / bloqueador de release.
- Ubicación: android/app/build.gradle.kts:38-42.
- Evidencia: el bloque release usa
  signingConfig = signingConfigs.getByName("debug").
- Impacto: la APK no tiene identidad de distribución propia. No es adecuada
  para publicar una primera versión estable y el cambio posterior a una
  keystore distinta impediría actualizar esa instalación de forma normal.
- Corrección: crear una keystore privada de producción, no introducirla en Git,
  configurar key.properties local o secretos de CI, firmar el release con esa
  clave y conservar una copia de respaldo segura.
- Mitigación temporal: no distribuir la APK actual como versión definitiva;
  usarla solo para pruebas internas.
- Falso positivo posible: si el APK es estrictamente interno y descartable, no
  afecta una prueba local; aun así bloquea la entrega solicitada.

### FN-SEC-002 — La política de actualización de domicilios es demasiado amplia

- Severidad: alta.
- Ubicación: supabase/migrations/001_initial_schema.sql:303-318 y
  supabase/migrations/009_global_customers_and_zone_couriers.sql:159-181.
  El cliente Flutter realiza el update directo en lib/main.dart:2080-2108.
- Evidencia: deliveries_update_relevant autoriza la actualización de toda la
  fila cuando la farmacia coincide con public.my_pharmacy_code(). RLS valida
  pertenencia de fila, pero no limita qué columnas puede cambiar el actor. La
  aplicación puede actualizar status, asignación y otros campos operativos
  desde el cliente.
- Impacto: una sesión de farmacia comprometida o un cliente modificado podría
  alterar el estado del domicilio, el domiciliario aceptado o datos económicos
  sin pasar por la máquina de estados y su auditoría prevista.
- Corrección: revocar los updates amplios para farmacia/domiciliario y exponer
  RPCs con operaciones concretas (publish, accept, picked_up, deliver, cancel,
  reassign). Cada RPC debe comprobar actor, estado anterior, zona/apoyo y
  escribir el evento de auditoría. Si se mantienen updates directos, usar una
  política de columnas y triggers que rechacen cambios sensibles fuera de la
  transición permitida.
- Mitigación temporal: no habilitar el piloto hasta ejecutar pruebas negativas
  con una sesión de farmacia y una de domiciliario.
- Falso positivo posible: la interfaz normal puede escribir solo estados
  permitidos; el problema está en la autorización de backend, por lo que esa
  protección de interfaz no es suficiente.

### FN-SEC-003 — El resumen global de cuotas se concede a cualquier usuario autenticado

- Severidad: alta / privacidad de datos operativos.
- Ubicación: supabase/migrations/018_shift_permissions_support_and_fee_fix.sql:77-112.
- Evidencia: get_admin_courier_fee_summary(date) es security definer, se
  concede a authenticated, devuelve todos los domiciliarios activos y no
  contiene una comprobación public.is_admin().
- Impacto: un usuario autenticado que conozca el nombre del RPC podría consultar
  nombres, días trabajados, dobles turnos, tarifa y deuda de todo el equipo.
- Corrección: añadir una comprobación obligatoria de administrador activo al
  inicio de la función y mantener el GRANT EXECUTE restringido a un rol/API
  controlado si el modelo lo permite. Añadir prueba negativa para farmacia y
  domiciliario.
- Mitigación temporal: no mostrar deuda global en una cuenta que no sea admin y
  aplicar la corrección SQL antes de compartir el enlace.
- Falso positivo posible: si la función aún no se aplicó al proyecto remoto, el
  riesgo no está activo allí; precisamente por eso hay que verificar la versión
  de migraciones en Supabase.

### FN-SEC-004 — CORS abierto en funciones Edge administrativas y de notificación

- Severidad: media.
- Ubicación: línea 5 de supabase/functions/admin-create-user/index.ts,
  admin-manage-pharmacy-profiles/index.ts, admin-reset-user-password/index.ts
  y send-push-notification/index.ts.
- Evidencia: Access-Control-Allow-Origin: *.
- Impacto: cualquier origen web puede intentar invocar los endpoints. El JWT y
  la validación del actor reducen el riesgo, pero el navegador queda con una
  superficie más amplia de la necesaria y se dificulta controlar qué dominios
  oficiales pueden ejecutar operaciones administrativas.
- Corrección: responder el origen solo si pertenece a la lista oficial, por
  ejemplo el dominio de GitHub Pages y el dominio final de producción; para
  orígenes no permitidos no devolver Access-Control-Allow-Origin. Mantener la
  validación de JWT: CORS no reemplaza autorización.
- Mitigación temporal: conservar la validación de sesión y revisar logs de
  invocaciones hasta restringir los orígenes.
- Falso positivo posible: CORS no permite por sí solo saltarse Supabase Auth; se
  reporta como endurecimiento y reducción de superficie, no como acceso
  anónimo confirmado.

### FN-SEC-005 — Falta una política de seguridad HTTP visible y se publican source maps

- Severidad: media/baja, endurecimiento.
- Ubicación: pharmacy_web/index.html:1-29 y pharmacy_web/vite.config.js:8-10.
- Evidencia: no hay CSP, frame-ancestors, Referrer-Policy,
  Permissions-Policy ni otros encabezados definidos en el proyecto; Vite
  configura sourcemap: true para el build público.
- Impacto: una futura inyección de HTML/JS tendría menos defensa en profundidad
  y los source maps exponen estructura y comentarios del código al público.
- Corrección: configurar encabezados en el hosting/CDN y una CSP compatible con
  Supabase; revisar explícitamente connect-src, img-src, media-src y worker-src.
  Publicar source maps solo si se necesitan para soporte y preferiblemente en
  almacenamiento privado.
- Mitigación temporal: React escapa el contenido JSX y no se encontró uso de
  dangerouslySetInnerHTML; aun así, eso no sustituye CSP.
- Falso positivo posible: GitHub Pages puede impedir configurar algunos
  headers; en ese caso usar un CDN/hosting delante o una configuración de
  seguridad compatible.

### FN-SEC-006 — Credencial de revisión incluida en README

- Severidad: media si el repositorio será público.
- Ubicación: README.md:165-168.
- Evidencia: el README incluye un correo y una contraseña literal de revisión.
- Impacto: cualquier persona con acceso al repositorio puede intentar entrar a
  ese usuario. Aunque sea una cuenta de pruebas, puede conservar datos o
  permisos que cambien con el tiempo.
- Corrección: quitar la contraseña del README, usar variables secretas para
  pruebas y rotar esa credencial si la cuenta existe o si el repositorio fue
  compartido públicamente.
- Mitigación temporal: desactivar la cuenta de revisión y crear usuarios de
  prueba aislados en un proyecto Supabase separado.
- Falso positivo posible: si la cuenta nunca fue creada, no hay acceso real,
  pero publicar contraseñas sigue siendo una mala práctica.

## Controles positivos verificados

- auth.getUser() se ejecuta en las funciones Edge antes de usar el cliente con
  service_role.
- Las funciones administrativas verifican rol admin y active = true.
- La clave secreta de Supabase se obtiene en funciones Edge y no se configura
  en pharmacy_web.
- Las tablas de equivalentes y chat revocan acceso al rol anon.
- Las políticas de chat comprueban pertenencia del domicilio y fijan el
  remitente desde la sesión.
- Las funciones SQL security definer revisadas usan set search_path = public.
- La firma manuscrita exige prefijo PNG base64 y tiene un límite de tamaño.
- npm audit --omit=dev terminó con 0 vulnerabilidades conocidas.

## Pruebas de seguridad que faltan

1. RPC negativa: farmacia no puede consultar get_admin_courier_fee_summary.
2. RPC/RLS negativa: farmacia no puede cambiar status, accepted_courier_id,
   amount o payment_method fuera de la operación autorizada.
3. Domicilio de una farmacia no aparece en otra farmacia.
4. Equivalente draft no aparece en farmacia hasta la firma.
5. Usuario inactivo no puede publicar, aceptar, chatear ni recibir push.
6. Function Edge sin JWT, JWT expirado y JWT de rol incorrecto devuelven 401/403.
7. Prueba de abuso de longitud para texto, productos, notas, teléfono y firma.
8. Verificación de que ningún .env, service account, keystore o token termine en
   Git.

## Prioridad recomendada

Resolver en este orden: FN-SEC-001 → FN-SEC-002 → FN-SEC-003 → FN-SEC-004 →
FN-SEC-006 → FN-SEC-005. Después repetir las pruebas negativas y guardar el
resultado como criterio de liberación.

