# Registro técnico — Observabilidad, prueba gratuita y recomendación de planes
Fecha: 2026-09-23

## Respaldo
Antes de iniciar esta etapa se creó la rama:
`backup/pre-observability-2026-09-23`

Esta rama conserva el estado anterior de `main` y sirve como punto de retorno.

## Objetivo
Centralizar en el administrador información de uso real, fallos técnicos, errores de uso y reportes enviados por restaurantes. Además, conservar el plan que interesó al restaurante al registrarse y sugerir posteriormente el plan mínimo que cubre los módulos que realmente utiliza.

## Cambios en base de datos
Migración aplicada: `observability_trial_intent_analytics`.

Se agregaron a `restaurants`:
- `trial_intended_plan_id`
- `trial_intended_plan_selected_at`

Se crearon:
- `app_events`: eventos de interacción.
- `app_errors`: errores separados entre fallos técnicos y errores de uso.
- `user_issue_reports`: reportes manuales enviados desde la aplicación.
- `observability_alert_log`: deduplicación de alertas enviadas al administrador.

RPC principales:
- `log_app_event`
- `log_app_error`
- `submit_issue_report`
- `admin_observability_summary`
- `admin_plan_recommendations`
- `create_my_trial_restaurant_v2(..., p_intended_plan_id)`

Las tablas de telemetría tienen RLS activado y el acceso directo para `anon` y `authenticated` fue revocado. El frontend escribe mediante RPC controlados.

## Dashboard administrador
Versión visible: v2.3.21.

Se agregó el bloque **Observabilidad** con:
- interacciones registradas;
- fallos técnicos;
- errores de uso;
- reportes abiertos;
- módulos más usados por restaurantes;
- secciones más utilizadas en el menú cliente;
- errores frecuentes;
- distribución de interés por plan;
- recomendación de plan según uso real;
- reportes recientes.

Filtros:
- 24 horas;
- 7 días;
- 30 días;
- todos los restaurantes o un restaurante específico usando el selector existente del dashboard.

### Diferencia entre fallo y error de uso
Ejemplos de **error de uso**:
- correo/contraseña incorrectos;
- intentar entrar como cliente con una cuenta de restaurante;
- validaciones del formulario.

Ejemplos de **fallo técnico**:
- excepción JavaScript;
- promesa rechazada no controlada;
- fallo al cargar panel o menú;
- error inesperado de autenticación o backend.

Esta separación evita tratar una contraseña incorrecta como una caída del sistema.

## Alertas sin tener que entrar al administrador
Edge Function desplegada:
`observability-admin-alert`

Comportamiento:
- Si se acumulan al menos 3 fallos técnicos durante 15 minutos, se envía una alerta por correo a los usuarios administradores.
- Los errores de uso no activan esta alerta.
- La alerta se deduplica para evitar correos repetidos durante la misma ventana.
- Un reporte manual enviado por un restaurante genera un aviso por correo al administrador.
- El correo utiliza la configuración de Resend ya existente del proyecto.

No se incluyen contraseñas, tokens, datos de tarjetas ni secretos dentro de la telemetría.

## Recomendación de plan
`admin_plan_recommendations` analiza los módulos utilizados durante el período y busca el plan activo de menor precio que cubra todos esos módulos.

La recomendación se muestra como ayuda informativa y no modifica automáticamente la suscripción.

También se conserva:
- plan que interesó al usuario al registrarse;
- plan sugerido por uso real;
- módulos que originaron la sugerencia.

## Eliminado
- La prueba gratuita dejó de considerarse una opción comercial independiente en la landing. Sigue existiendo como plan técnico predeterminado en la base de datos porque es el que aplica los permisos de los 30 días gratis.
- No se eliminó el registro de prueba de `subscription_plans`; solo se oculta del catálogo público.

## Próximos pasos recomendados
- Acumular datos reales durante varios días antes de tomar decisiones comerciales.
- Revisar las recomendaciones de plan y ajustar módulos/planes si el comportamiento real lo justifica.
- Añadir estados de gestión para los reportes desde el admin (en revisión/resuelto) si se necesita un flujo de soporte más completo.
- Evaluar alertas push además del correo si se desea una segunda vía de aviso.

## Rollback
Código:
1. Revisar la rama `backup/pre-observability-2026-09-23`.
2. Comparar contra `main`.
3. Revertir commits de esta etapa si fuera necesario.

Base de datos:
No borrar tablas de telemetría durante un rollback de frontend; primero exportar los datos. Las columnas nuevas son aditivas y no modifican los datos históricos de pedidos, caja, productos o clientes.
