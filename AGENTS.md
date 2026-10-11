# Reglas de trabajo de FarmaNorte

- Responder en español y de forma resumida.
- Trabajar por etapas; no iniciar la siguiente hasta cerrar la actual.
- Puerta de cada etapa: implementar, auditar, corregir hallazgos y auditar de
  nuevo. Solo avanzar cuando el resultado esté aprobado.
- Toda modificación funcional móvil debe terminar con `flutter analyze`,
  `flutter test` y una compilación APK de revisión.
- No guardar claves secretas, `service_role` ni credenciales privadas en el
  código o en la APK.
- Arquitectura acordada: página web de farmacias en Hostinger, Supabase como
  backend compartido, APK Android y PWA para domiciliarios con iPhone.
- El piloto final se definirá cuando la aplicación, la página de farmacias y
  las auditorías estén terminadas. No asumir una farmacia ni ejecutar una
  semilla de piloto antes de esa decisión.
- La etapa 1 se valida con el proyecto Supabase real; las pruebas integrales
  de publicación, operación y cierre se completan durante las etapas de
  producto antes de autorizar el piloto.
