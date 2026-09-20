# Auditoría del sistema de monitoreo

Fecha de revisión: 2026-09-20

| Capacidad | Estado | Implementación actual |
|---|---|---|
| Calidad en cada push | Implementado | Los tres repositorios ejecutan validación estática, control de secretos y Playwright. |
| Bloqueo antes de producción | Preparado | Los checks existen; la rama `main` debe exigirlos mediante Rulesets de GitHub. |
| Monitor de dominios | Implementado | Cliente, landing, panel restaurante y administración cada cinco minutos. |
| Robot de producción | Implementado | Recorridos de cliente, carrito, checkout, paneles y contraste cada quince minutos. |
| Login automático | Preparado | Se activa al configurar cuentas sintéticas en GitHub Secrets. |
| Supabase Data API | Implementado | Consulta segura de lectura usando clave publicable. |
| Supabase Auth | Implementado | Comprueba el endpoint de salud de Auth. |
| Supabase Storage | Implementado | Comprueba el endpoint de estado de Storage. |
| Edge Function de pagos | Implementado | Comprueba disponibilidad mediante `OPTIONS`, sin crear cobros. |
| Pedidos sintéticos | Pendiente controlado | Requiere restaurante, usuario y datos exclusivamente de Sandbox. |
| Mercado Pago Sandbox | Pendiente controlado | Requiere credenciales de prueba separadas de producción. |
| Umbrales de latencia | Implementado | Advertencia y estado crítico por servicio. |
| Centro de incidencias | Implementado | Abre, actualiza y cierra incidencias en GitHub sin comentarios repetitivos. |
| WhatsApp | Preparado | Se activa con tres secretos de WhatsApp Business Cloud API. |
| Diagnóstico automático | Implementado | Clasifica fallos y propone una acción según servicio, HTTP y latencia. |
| Diagnóstico mediante IA | Pendiente controlado | Requiere proveedor, presupuesto, política de privacidad y secreto de API. |
| Staging independiente | Pendiente | Requiere elegir dominio y proveedor de hosting de preproducción. |
| Dependencias | Implementado | Dependabot revisa Playwright mensualmente en los tres repositorios. |

## Cuentas sintéticas necesarias

Las pruebas autenticadas nunca deben usar cuentas personales o de clientes. Configurar:

- `ADMIN_TEST_EMAIL`
- `ADMIN_TEST_PASSWORD`
- `RESTAURANT_TEST_EMAIL`
- `RESTAURANT_TEST_PASSWORD`

## Activación de WhatsApp

- `WHATSAPP_TOKEN`
- `WHATSAPP_PHONE_NUMBER_ID`
- `WHATSAPP_TO`

## Siguiente ampliación segura

Crear un restaurante marcado exclusivamente como monitor, credenciales Mercado Pago Sandbox y una función transaccional que cree un pedido, confirme que aparece en restaurante/administración y elimine únicamente ese dato sintético. No debe reutilizar restaurantes ni credenciales de producción.
