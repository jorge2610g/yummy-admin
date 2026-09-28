# YummyPro · Dominios personalizados por negocio

Fecha de inicio: 2026-09-28  
Estado: **EN PROGRESO · NÚCLEO IMPLEMENTADO EN STAGING · PRODUCCIÓN INTACTA**  
Responsable de continuidad: cualquier IA debe leer este archivo antes de tocar esta funcionalidad.

## Objetivo

Permitir que cada negocio YummyPro conecte su propio dominio público, por ejemplo:

- `www.mirestaurante.com`
- `menu.mirestaurante.com`
- `tienda.minimarket.cl`

El dominio debe abrir directamente el sitio público del negocio sin exigir `?r=slug` ni `?business=id`, mantener HTTPS y resolver siempre el negocio correcto.

No se pretende mover los paneles administrativos a dominios de clientes. El alcance inicial es la experiencia pública de Restaurante, Retail, Profesionales y Streaming.

## Regla de ambientes

- Desarrollo y validación: ramas `staging` + Supabase Staging `wodqqheeesrelsbacmgx`.
- Producción: **NO MODIFICADA** durante esta implementación.
- El release anterior estaba cerrado antes de iniciar esta tarea: `yummy-admin main = staging` en `f44b57c5433fdbfdfbf351b021891192966e2aee`.

## Base de datos · Supabase Staging

Migración registrada en Staging:

`20260928061509_business_custom_domains`

Archivo versionado:

`supabase/migrations/20260928061509_business_custom_domains.sql`

### Estructura

Se reutiliza `public.restaurants.custom_domain` como hostname activo final.

Se agregó `public.business_custom_domains` para el ciclo de vida de conexión:

- `pending_dns`
- `dns_verified`
- `provisioning`
- `active`
- `failed`
- `disabled`

Incluye token de verificación, estado SSL, id del proveedor, fechas y último error.

El acceso directo a esta tabla está revocado para `anon` y `authenticated`. Tiene RLS habilitado y se opera mediante RPC autenticados o backend con `service_role`.

### RPC creados

- `get_business_custom_domain(restaurant_id)`
  - solo usuario autenticado que pueda administrar el negocio.
  - devuelve dominio activo y/o solicitud pendiente.
- `request_business_custom_domain(restaurant_id, hostname)`
  - normaliza y valida hostname.
  - evita dominios reservados de YummyPro/GitHub/Supabase.
  - evita reclamar un hostname ya usado por otro negocio.
- `remove_business_custom_domain(restaurant_id, hostname)`
  - desvincula la solicitud/activo del negocio.
- `service_activate_business_custom_domain(...)`
  - solo `service_role`.
  - no activa un hostname si no fue verificado previamente.

### Protección adicional

Trigger `restaurants_verified_custom_domain_guard`:

Nadie puede escribir arbitrariamente `restaurants.custom_domain` salvo que exista un registro `business_custom_domains` activo para ese mismo negocio/hostname. Limpiar el dominio a NULL sí está permitido.

### Streaming

`streaming_public_catalog(p_ref text)` ahora acepta:

- id
- slug
- custom domain

Esto permite resolver un catálogo Streaming desde un hostname personalizado.

## Verificación DNS

Edge Function Staging:

`verify-business-domain`

Estado: ACTIVE · verify_jwt=true.

Flujo:

1. El usuario autenticado registra el dominio.
2. YummyPro muestra:
   - TXT: `_yummypro.<dominio>`
   - valor: `yummypro-verification=<uuid>`
   - CNAME: `<dominio> -> domains.yummypro.online`
3. El usuario pulsa **Verificar DNS**.
4. La Edge Function consulta DNS vía DNS-over-HTTPS.
5. Si TXT y CNAME coinciden, el estado pasa a `dns_verified`.

Verificar DNS **no** equivale todavía a activar el dominio. La activación final requiere que el proveedor de edge/SSL haya aprovisionado el hostname y su certificado.

## Interfaz de negocio

Se agregó `/* YummyPro Custom Domains v1 */` a `panel/professional.js` de las cuatro verticales.

La pestaña **🌐 Dominio** aparece dentro de Configuración e incluye:

- campo de dominio
- Conectar dominio
- instrucciones TXT/CNAME
- Verificar DNS
- estado actual
- Quitar dominio
- enlace para abrirlo cuando esté activo

Commits iniciales:

- Restaurante: `6a379668b528f089a5ce886e604c50819403be3a`
- Retail: `74ad17f05402c9dbcf5c2b48dfd206be90c8447c`
- Profesionales: `d877a1aa3d0ac9a3355d9e416b2e21b34781ba21`
- Streaming UI: `d316c3cdaf772a6a2963cdc9ac89665c67477c52`

## Resolución pública

### Cliente · mipagina

Commit:

`d55253bd00e0383de7465038fbd9ea73f17b1fdd`

Cambio importante:

Antes, solo `menu.yummypro.online` se consideraba Producción. Un dominio de cliente podía terminar usando Supabase Staging por error.

Ahora:

- GitHub Pages de Pruebas y localhost => Staging.
- cualquier hostname público real => Producción.

El cliente ya tenía lógica para consultar `restaurants.custom_domain` cuando el hostname no es un host de plataforma.

### Streaming catálogo

Commit vigente de esta etapa:

`380aacdbda2613986105476c604e04c2d5b5bb89`

Ahora un hostname personalizado:

- se considera Producción
- se usa como `businessRef`
- se resuelve por `streaming_public_catalog(p_ref)`
- después de resolver se obtiene el `businessId` real.

## CI comprobado hasta ahora

En los HEAD funcionales:

- Restaurante: quality ✅ / environment guard ✅ / smoke estaba ejecutándose al último chequeo.
- Retail: quality ✅ / environment guard ✅ / smoke estaba ejecutándose.
- Profesionales: quality ✅ / environment guard ✅ / smoke estaba ejecutándose.
- Streaming: quality ✅ / environment guard ✅ / smoke estaba ejecutándose.
- Cliente: quality ✅ / environment guard ✅ / smoke estaba ejecutándose.

Volver a comprobar los smoke antes de continuar a release.

## Infraestructura que FALTA

**No afirmar que un dominio real ya puede quedar activo.**

Falta la capa que acepte hostnames arbitrarios y entregue HTTPS. El diseño elegido es Cloudflare for SaaS / Custom Hostnames.

Se necesita:

1. Una zona Cloudflare de YummyPro.
2. Un hostname de fallback/gateway, previsto como:
   `domains.yummypro.online`
3. Un origen/gateway que acepte cualquier `Host` de cliente.
4. Credencial Cloudflare con permiso mínimo para Custom Hostnames / SSL.
5. Crear el Custom Hostname después del TXT/CNAME verificado.
6. Esperar:
   - custom hostname `status=active`
   - SSL `status=active`
7. Recién entonces llamar `service_activate_business_custom_domain`.

No hay conector Cloudflare instalado/disponible en esta sesión, por lo que esta parte todavía **no fue desplegada**.

### Por qué no basta GitHub Pages

GitHub Pages publica los sitios de YummyPro, pero no es una puerta multi-tenant diseñada para aceptar miles de hostnames arbitrarios de clientes. Hace falta un edge gateway que reciba el dominio del cliente y sirva/proxifique la aplicación correcta.

La opción prevista es un Cloudflare Worker detrás de Cloudflare for SaaS.

## Siguiente paso exacto

1. Confirmar todos los smoke tests actuales.
2. Implementar/versionar el Worker `custom-domain-gateway`.
3. Configurar `domains.yummypro.online` como fallback/gateway en Cloudflare.
4. Crear una Edge Function de aprovisionamiento que:
   - requiera usuario autorizado
   - solo procese registros `dns_verified`
   - llame a Cloudflare Custom Hostnames
   - almacene el provider hostname id
   - consulte estado/SSL
   - active el dominio solo al estar ambos en `active`.
5. Probar con **un dominio de pruebas real**.
6. Ejecutar Auditor/quality/smoke.
7. Solo entonces preparar el release coordinado.
8. Aplicar la migración a Producción únicamente durante el release autorizado.

## Consideraciones de seguridad

- El token de Cloudflare nunca debe estar en frontend ni en GitHub público.
- Debe vivir como secreto de backend.
- `service_role` nunca se entrega al navegador.
- Un usuario solo puede solicitar/quitar dominios de negocios que puede administrar.
- Un dominio no puede quedar activo por simple UPDATE en `restaurants`.
- La verificación TXT demuestra control DNS antes del aprovisionamiento.
- Los dominios oficiales de YummyPro y de infraestructura están reservados.

## Notas para otra IA

No recrear la tabla ni los RPC desde cero: la migración `20260928061509_business_custom_domains` ya está aplicada en Supabase Staging y versionada.

No usar `custom_domain` como “activo” antes de SSL. La fuente de verdad del proceso es `business_custom_domains`; `restaurants.custom_domain` solo se rellena al final.

No promover nada a Producción hasta cerrar el gateway externo y una prueba real end-to-end.
