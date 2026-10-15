# Auditoría integral de FarmaNorte · histórico

> Este documento conserva el corte inicial de la auditoría. El estado vigente
> está en [AUDITORIA-FINAL-2026-10-12.md](AUDITORIA-FINAL-2026-10-12.md).

Fecha: 2026-10-12  
Alcance: APK Flutter, página web de farmacias, Supabase, funciones Edge,
Realtime, notificaciones, equivalentes, cuotas, publicación y preparación del
piloto.

## Resultado ejecutivo

### Avance del plan: 62/100

El proyecto tiene una base funcional real y ya no es solamente una maqueta:
hay autenticación de Supabase, roles, RLS, Realtime, turnos, apoyo general,
publicación de domicilios, chat, equivalentes y una APK release compilable. Sin
embargo, el producto todavía no debe entregarse como operación abierta esta
semana sin cerrar la puerta de liberación: notificaciones de fondo, firma de
producción, pruebas de extremo a extremo con usuarios reales y dos controles de
autorización del backend.

Este porcentaje mide avance funcional y técnico del producto completo. La
preparación para una entrega real inmediata es menor: aproximadamente 35/100
hasta cerrar los bloqueadores P0 de la sección de prioridades.

El repositorio documenta una etapa 0 de reglas y siete etapas de entrega. Para
respetar tu forma de medirlo, la tabla principal cuenta las etapas 1 a 7; la
etapa 0 se reporta aparte como fundamento.

## Estado por etapa

| Etapa | Estado actual | Avance | Lo que ya está fuerte | Lo que impide declararla cerrada |
|---|---|---:|---|---|
| 0. Reglas y alcance | Base avanzada | 92% | Reglas de zonas, apoyo, turnos, perfiles, firma, chat y equivalentes documentadas | Hay decisiones que deben congelarse: política de cobro, cambio de contraseña temporal, perfiles de farmacia y alcance exacto del cliente compartido |
| 1. Supabase y base técnica | Base real preparada | 84% | Auth, roles, RLS, Realtime, auditoría, migraciones y funciones seguras | Falta comprobar en el proyecto Supabase activo que todas las migraciones 010–019 estén aplicadas y corregir autorización de actualizaciones sensibles |
| 2. Panel administrativo | Funcionalmente avanzado | 86% | Usuarios, roles, perfiles de farmacia, restablecimiento, turnos agrupados, apoyo y cuotas | Falta E2E real, cambio obligatorio de clave temporal, bitácora administrativa y prueba de errores con la base real |
| 3. Página de farmacias | Base operativa real | 77% | Login real, validación de farmacia, operaciones, pedidos, chat, equivalentes, PDF/imagen y PWA | Falta probar una cuenta/perfil real, notificación web fuera de la pestaña, endurecimiento HTTP/CSP, rendimiento y cierre de la decisión sobre clientes/documentos |
| 4. Operación del domiciliario | Parcialmente real | 58% | Turnos, apoyo general, aceptación, estado del domicilio, historial, firma manual y configuración de sonido | La aprobación de un segundo domicilio todavía está explícitamente pendiente en el backend real; falta probar cola, concurrencia, expiración y reasignación en dispositivo físico |
| 5. Tiempo real y comunicación | Implementación parcial | 43% | Chat Realtime, sonidos locales, código FCM y función Edge de notificaciones | La APK auditada no fue compilada con variables Firebase; la web no tiene Web Push; falta probar fondo, app terminada, reconexión y notificación real |
| 6. Equivalentes, cuotas y ganancias | Modelo y UI avanzados | 58% | Firma manuscrita, estados pendiente/firmado/recibido/pagado, PDF/imagen, cuota diaria, doble turno y configuración de liquidación | Falta E2E contable, conciliación de pagos, descansos, deuda semanal, ganancias y verificación de que solo una firma libera el soporte |
| 7. Despliegue y piloto | Preparación inicial | 25% | APK release compilable, build web correcto y PWA preparada | APK firmada con clave debug, sin remote Git configurado en este checkout, sin CI/CD, sin Firebase activo, sin prueba física y sin matriz de rollback/backup |

La media simple de las siete etapas es 61,6%, redondeada a 62%. No se sube
artificialmente el porcentaje por tener muchas pantallas: los flujos críticos
que conectan farmacia, domiciliario y backend pesan más que una pantalla
terminada.

## Evidencia verificada

- flutter analyze --no-fatal-infos: sin problemas reportados en la última
  verificación.
- flutter test: 16 pruebas aprobadas en la última verificación.
- flutter build apk --release: correcto con URL y clave pública de Supabase.
- APK actual: build/app/outputs/flutter-apk/app-release.apk
- Tamaño actual: 64.146.530 bytes.
- SHA-256 actual:
  1C6D0F86FF18EB01FBA0ED56E4E5095EB48FDE0F988607E4BA36A789FDCA3EFB.
- npm test en pharmacy_web: 6 pruebas aprobadas, 1 omitida porque la prueba
  que necesita backend real no se ejecutó con la variable de entorno de backend
  real en esta auditoría.
- npm audit --omit=dev: 0 vulnerabilidades reportadas.
- npm run build: correcto. Vite advierte que el paquete inicial supera 500 kB;
  el bundle principal está alrededor de 843 kB.
- No había un teléfono Android físico conectado durante esta auditoría.
- El checkout actual no tiene git remote configurado y no tiene workflows en
  .github/workflows/.
- El árbol de trabajo está muy sucio y contiene cambios previos, migraciones y
  artefactos no rastreados. Antes de una entrega debe hacerse una revisión de
  qué cambios entran en el release y cuáles son temporales.

## Puntos fuertes

1. La autenticación ya usa Supabase Auth y el perfil se valida en backend; el
   modo local está separado del flujo normal de producción.
2. La decisión de no borrar usuarios para conservar historial está bien
   reflejada en el modelo de perfiles: conviene desactivar y restablecer clave.
3. La lógica de apoyo general está modelada en la base: un turno support no
   exige farmacia concreta y puede elegirse en la consulta de domiciliarios de
   una farmacia.
4. La firma del equivalente ya tiene un camino de firma dibujada y una
   liberación controlada: el equivalente puede quedar pendiente hasta que el
   domiciliario firme.
5. El chat utiliza Realtime y las migraciones fijan el remitente desde la
   sesión, en vez de confiar en el nombre enviado por el cliente.
6. La página de farmacia no contiene una clave service_role; usa la clave
   pública de Supabase y deja el secreto en funciones Edge.
7. Hay pruebas de login, viewport móvil, configuración explícita y errores de
   credenciales; esto reduce el riesgo de volver a una pantalla en blanco.

## Bloqueadores antes de entregar

### P0 — no entregar sin resolver

1. Firma de APK de producción. android/app/build.gradle.kts todavía utiliza la
   clave debug para el tipo release. Una APK así no es una entrega de
   producción: debe crearse una keystore privada, guardarla fuera del
   repositorio y configurar el release con secretos de CI o del equipo de
   compilación.
2. Notificaciones reales de fondo. El código FCM está preparado, pero la APK
   actual fue construida con las variables de Supabase y no con las variables
   Firebase. Hay que configurar el proyecto Firebase, el secreto de servicio
   en Supabase, compilar una APK con FCM y probar en un Android real: abierta,
   minimizada, cerrada normalmente, sin red y después de reabrir. Una
   detención forzada desde Ajustes no puede garantizarse en Android.
3. Prueba E2E controlada, sin datos inventados. Crear una cuenta real de
   farmacia y un domiciliario de prueba, publicar un domicilio, aceptarlo,
   avanzar el estado, firmar el equivalente, verlo en la farmacia, confirmar
   recepción y registrar pago. Después limpiar solamente los datos de prueba
   con un procedimiento reversible y dejar evidencia.
4. Corregir autorización sobre domicilios. Las políticas actuales permiten a
   una farmacia actualizar cualquier columna de sus propios domicilios si la
   fila sigue siendo de su farmacia. Eso puede saltarse transiciones de estado,
   domiciliario asignado o valores económicos. La operación debe pasar por
   RPCs de transición y no por un update libre desde el cliente.
5. Cerrar acceso al resumen de cuotas. get_admin_courier_fee_summary se concede
   a authenticated, pero la función no comprueba que quien la llame sea
   administrador. Debe restringirse antes de mostrar deuda y ganancias de todo
   el equipo.

### P1 — resolver antes del piloto real

1. Implementar o cerrar la aprobación de un segundo domicilio en el backend
   real; hoy el APK muestra que todavía no está habilitada para Supabase real.
2. Probar reasignación por farmacia, apoyo general y concurrencia: dos
   domiciliarios intentando aceptar el mismo domicilio, un apoyo fuera de su
   farmacia base y un domiciliario saturado.
3. Cambiar CORS * de las funciones Edge por una lista de orígenes oficiales.
4. Añadir CSP y encabezados de seguridad en el hosting de la web; evitar
   publicar source maps en el sitio público si no son necesarios.
5. Decidir de manera definitiva el modelo de clientes. El formulario actual ya
   no muestra documento y envía customer_id/customer_address_id nulos, pero
   las migraciones antiguas todavía conservan tablas y reglas de clientes por
   documento. No se debe mantener una promesa de cliente global si la
   operación final será solamente nombre, teléfono y dirección.
6. Agregar monitorización visible de fallos de notificación. Hoy la publicación
   y el chat pueden completarse aunque la llamada push falle; el error se deja
   en consola.
7. Probar el chat con pestaña oculta y navegador cerrado. El service worker
   actual es de caché de recursos; no implementa un evento Web Push ni una
   notificación de navegador.
8. Corregir documentación de release: el README aún tiene tamaño, hash y
   fecha de una APK anterior y contiene una credencial de revisión que no debe
   quedar en un repositorio público.

### P2 — completar para llegar al 100%

1. Registrar deuda por período: cuota diaria, días descansados, doble turno,
   pagos parciales, saldo y comprobante de liquidación.
2. Añadir bitácora administrativa para creación, desactivación, restablecimiento
   de clave, reasignación y confirmación de pagos.
3. Dividir el bundle web y cargar PDF/imagen bajo demanda; esto mejora el inicio
   en computadores de farmacia y conexiones lentas.
4. Completar matriz de accesibilidad: teclado, foco, mensajes de error,
   contraste, lector de pantalla y estados de carga.
5. Definir backups, rollback y recuperación del proyecto Supabase antes del
   primer día de operación.
6. Preparar PWA para iPhone como solución provisional. La aplicación nativa
   iOS seguirá necesitando Apple Developer, firma y un entorno macOS para el
   build final.

## Auditoría de UI y experiencia

Se revisó únicamente con evidencia disponible en código y pruebas, sin inventar
problemas visuales no observados.

1. Login móvil: la prueba automatizada comprueba que el ancho no desborde y que
   el botón de entrada quede dentro del viewport de 390 × 844. Este punto está
   mejor que antes, pero falta validación física en Android de gama baja.
2. Rendimiento de la web: el build funciona, aunque Vite advierte un bundle
   inicial grande. Conviene separar el formulario operativo, chat y exportación
   de equivalentes para que el login y los pedidos iniciales carguen antes.
3. PWA y actualización: el service worker usa una caché fija
   farmanorte-pharmacy-shell-v1 y no elimina cachés antiguas. Hay que versionar
   el nombre, limpiar versiones previas y verificar que una actualización no
   deje a una farmacia usando una interfaz vieja.

## Estimación de trabajo

Las horas son de trabajo técnico concentrado y suponen que las credenciales del
proyecto, una cuenta de prueba y al menos un Android están disponibles. No
incluyen esperas de Apple, revisión de tiendas ni tiempos de red.

| Paquete | Horas | A 4 h/día | A 2 h/día |
|---|---:|---:|---:|
| P0: seguridad de backend, Firebase, firma release y E2E mínimo | 20–30 h | 5–8 días | 10–15 días |
| P1: endurecimiento, segundo domicilio, push/web, perfiles y despliegue reproducible | 18–28 h adicionales | 5–7 días adicionales | 9–14 días adicionales |
| P2: cuotas completas, bitácora, rendimiento, accesibilidad y operación | 24–40 h adicionales | 6–10 días adicionales | 12–20 días adicionales |

Para entregar algo controlado esta semana, recomiendo congelar el alcance en un
MVP de una farmacia y completar primero P0. Eso representa aproximadamente
20–30 horas. A cuatro horas diarias son unos 5–8 días; a dos horas diarias,
10–15 días. Declarar el plan completo al 100% en la misma semana no es una
estimación responsable mientras falten firma de producción, Firebase y pruebas
físicas.

## Criterio de listo para piloto

- [ ] Release firmado con keystore de producción y número de versión único.
- [ ] Supabase con migraciones comprobadas, backup y plan de rollback.
- [ ] RLS negativa probada: farmacia no puede cambiar estado, asignación ni
  montos de forma arbitraria; solo puede usar las operaciones autorizadas.
- [ ] Solo un administrador puede consultar deuda global del equipo.
- [ ] Una cuenta real de farmacia y perfiles activos probados.
- [ ] Turnos de la semana publicados; apoyo general visible para las farmacias
  que correspondan.
- [ ] Flujo real: publicar → notificar → aceptar → recoger → entregar → firmar
  → farmacia recibe → pago.
- [ ] Push probado en segundo plano y chat probado en ambos sentidos.
- [ ] Equivalente descargable idéntico en web y APK.
- [ ] Cero domicilios ficticios y cero usuarios de demostración en producción.
- [ ] Registro de errores, respaldo y contacto de soporte definidos.

## GitHub y actualización del enlace

Sí: la web se puede actualizar en GitHub y, si el repositorio publica GitHub
Pages, el enlace se actualiza después de publicar el nuevo dist según la
configuración del repositorio. También puede hacerse con GitHub Actions para
que cada push ejecute npm ci, npm run build y despliegue.

En este checkout concreto, git remote -v no devuelve ningún remoto y no hay
workflow en .github/workflows/. Por tanto, los cambios locales actuales no se
están subiendo automáticamente. Para activarlo hace falta:

1. Confirmar el repositorio destino.
2. Configurar origin y autenticación de GitHub.
3. Separar los cambios de trabajo y artefactos temporales.
4. Cometer solamente el código y las migraciones aprobadas.
5. Configurar las variables VITE_SUPABASE_URL y
   VITE_SUPABASE_PUBLISHABLE_KEY como variables públicas de build, nunca la
   clave secreta de Supabase.
6. Crear el workflow de build/deploy y probar que el enlace carga la versión
   nueva, no una caché anterior.

No hice commit, push, despliegue ni cambios en Supabase durante esta auditoría.
Eso debe hacerse después de cerrar los hallazgos P0 y de confirmar qué archivos
del árbol de trabajo pertenecen al release.

## Conclusión

El proyecto está alrededor de 62% de avance completo y alrededor de 35% de
preparación para una entrega real inmediata. La diferencia no significa que
haya que rehacer la aplicación: significa que la base está construida, pero
los puntos de producción —firma, push real, autorización fina, prueba física,
despliegue reproducible y E2E— todavía son los que deciden si una farmacia la
puede usar sin sorpresas.

El orden recomendado es: seguridad de backend → firma/Firebase → E2E de una
farmacia → segundo domicilio y push web → despliegue GitHub → cuotas y
acabados.

