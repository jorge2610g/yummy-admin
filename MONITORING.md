# Monitor de Express Delivery

El workflow `Monitor de producción` comprueba cada cinco minutos cliente, restaurante, panel restaurante, administración, Supabase y la disponibilidad del servicio de pagos. Abre una única incidencia con la etiqueta `monitor`, añade eventos mientras persista el fallo y la cierra cuando el sistema se recupera.

## Secretos opcionales

- `ADMIN_TEST_EMAIL` y `ADMIN_TEST_PASSWORD`: cuenta administrativa exclusiva de pruebas.
- `WHATSAPP_TOKEN`: token de WhatsApp Business Cloud API.
- `WHATSAPP_PHONE_NUMBER_ID`: identificador del número emisor.
- `WHATSAPP_TO`: número receptor en formato internacional, solamente dígitos.

Las credenciales deben configurarse en **Settings → Secrets and variables → Actions**. Nunca deben copiarse al repositorio.

## Seguridad de pagos

El monitor solamente comprueba que la Edge Function de pagos sea alcanzable. No crea preferencias ni realiza cargos. Las pruebas transaccionales deberán usar una cuenta y credenciales separadas de Mercado Pago Sandbox.

## Protección recomendada

En la rama `main`, activa una regla que exija el workflow de calidad antes de aceptar cambios. Sin una regla de protección, GitHub ejecuta las pruebas pero no puede impedir que un push directo quede publicado.
