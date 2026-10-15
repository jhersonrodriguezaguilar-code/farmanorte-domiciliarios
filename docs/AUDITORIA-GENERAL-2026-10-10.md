# Auditoría general de FarmaNorte

Fecha: 2026-10-10

## Porcentaje global

**57/100 del plan completo.**

Este porcentaje mide avance funcional del producto completo, no solo la
cantidad de pantallas. La base real y el panel administrativo están avanzados,
pero todavía faltan los flujos que convierten la aplicación en una operación de
domicilios productiva.

## Estado por etapa

| Etapa | Estado real | Avance estimado |
|---|---|---:|
| 0. Reglas y alcance | Reglas principales documentadas; quedan algunas decisiones operativas | 95% |
| 1. Supabase y base técnica | Auth, RLS, Realtime, esquema, auditoría y usuario admin reales | 90% |
| 2. Panel administrativo | Catálogo real, usuarios, calendario agrupado, PDF, sesión persistente y cambio de clave | 92% |
| 3. Página de farmacias | Base web real, clientes por documento, direcciones y publicación implementadas | 65% |
| 4. Operación del domiciliario | Interfaz y modelos iniciales; falta el flujo real completo de ofertas | 40% |
| 5. Tiempo real y comunicación | Falta conectar notificaciones, chat, llamadas, GPS y fotos en operación | 25% |
| 6. Cuotas y equivalentes | Reglas identificadas, cálculo y registro operativo pendientes | 20% |
| 7. Despliegue y piloto | APK compilada; faltan prueba física, Hostinger, E2E y piloto | 10% |

## Comprobaciones hechas en esta auditoría

- `flutter analyze --no-pub`: sin problemas.
- `flutter test --no-pub`: 12 pruebas aprobadas.
- `flutter build apk --release --no-pub` con URL y clave pública reales:
  correcto.
- `pharmacy_web`: `npm run build` con URL y clave pública reales: correcto.
- `pharmacy_web`: Playwright real contra Supabase: 2 pruebas aprobadas con el
  entorno real; sin configuración, el smoke también conserva el estado vacío
  honesto.
- Supabase real: 8 zonas, 21 farmacias, 21 relaciones y 0 inconsistencias de
  catálogo.
- Supabase real: `Curva del Diablo` corregida.
- Supabase real: `shifts.pharmacy_code` nullable y clave generada
  `pharmacy_key` verificadas.
- Supabase real: dos Edge Functions administrativas publicadas y protegidas.
- No se escogió farmacia piloto ni se generaron domicilios ficticios.

APK de esta revisión:

- Ruta: `build/app/outputs/flutter-apk/app-release.apk`
- Tamaño: 57.949.585 bytes
- SHA-256: `E6D068B01EF4FFEB8FDEFFDD25087157705F488855D2EE1ED0CF8954B2A67C9E`

## Pendientes que bloquean el 100%

1. Guardar y verificar una semana real desde Supabase, administración y APK de
   domiciliario.
2. Crear un usuario real de farmacia sin elegir todavía el piloto.
3. Desplegar y probar la página con ese usuario: cliente, varias direcciones,
   publicación y Realtime.
4. Implementar y probar notificación, oferta de 5 minutos, aceptación,
   aprobación de segundo domicilio, cola, cancelación y entrega.
5. Implementar chat, llamadas, GPS, fotos opcionales y registro completo de
   eventos.
6. Implementar cuota semanal, doble turno, equivalentes virtuales y ganancias.
7. Exigir cambio de contraseña temporal en el primer ingreso.
8. Probar en teléfono Android, preparar acceso PWA para iPhone y desplegar en
   Hostinger.
9. Auditar todo y escoger la farmacia piloto únicamente al final.

## Próximo paso

Cerrar la etapa 2 con una semana de turnos reales y pasar a la etapa 3:
crear el primer usuario de farmacia y probar la página contra Supabase real,
sin crear datos de piloto.
