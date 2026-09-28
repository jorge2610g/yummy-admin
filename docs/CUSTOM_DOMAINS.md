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

### Requisito de plan

Los dominios personalizados son exclusivos de cuentas con plan **Pro** y suscripción en
estado **active**. La interfaz lo comunica antes de iniciar el proceso y las funciones de
base de datos vuelven a validarlo al solicitar y al activar el dominio; no puede omitirse
desde el navegador ni desde una llamada directa a la API.

### Instrucciones que verá el negocio

1. Escribir el dominio público, por ejemplo `www.minegocio.com`, sin `https://` ni rutas.
2. Pulsar **Conectar dominio**.
3. Crear exactamente el TXT y CNAME que YummyPro muestra en el proveedor DNS.
4. Esperar la propagación y pulsar **Verificar DNS**. HTTPS se aprovisiona automáticamente.

YummyPro no solicita transferir la propiedad del dominio. El negocio no debe eliminar sus
registros existentes de correo o web.

### Streaming

`streaming_public_catalog(p_ref text)` ahora acepta:

- id
- slug
- custom domain

Esto permite resolver un catálogo Streaming desde un hostname personalizado.

## Verificación DNS

Edge Function Staging (fuente versionada en `supabase/functions/verify-business-domain/index.ts`):

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

En los HEAD funcionales actuales:

- Restaurante `6a379668b528f089a5ce886e604c50819403be3a`: quality ✅ / environment guard ✅ / smoke ✅.
- Retail `74ad17f05402c9dbcf5c2b48dfd206be90c8447c`: quality ✅ / environment guard ✅ / smoke ✅.
- Profesionales `d877a1aa3d0ac9a3355d9e416b2e21b34781ba21`: quality ✅ / environment guard ✅ / smoke ✅.
- Streaming `380aacdbda2613986105476c604e04c2d5b5bb89`: quality ✅ / environment guard ✅ / smoke ✅.
- Cliente `d55253bd00e0383de7465038fbd9ea73f17b1fdd`: quality ✅ / environment guard ✅ / smoke ✅.

Los smoke iniciales vencieron esperando la publicación de los repositorios `*-pruebas`. Después de publicar los SHAs exactos, se relanzaron los jobs fallidos y los cinco terminaron en `success`.

## Aprovisionamiento Cloudflare preparado en backend

Edge Function Staging (fuente versionada en `supabase/functions/provision-business-domain/index.ts`):

`provision-business-domain`

Estado: ACTIVE · verify_jwt=true.

La función ya implementa el flujo de backend:

1. autentica al usuario;
2. confirma que administra el negocio;
3. exige estado `dns_verified`;
4. crea el Custom Hostname en Cloudflare si todavía no existe;
5. guarda `provider_hostname_id`;
6. consulta los estados del hostname y SSL;
7. solo cuando ambos están en `active`, llama a `service_activate_business_custom_domain`.

Después de una verificación DNS exitosa, la interfaz invoca este aprovisionamiento; si Cloudflare aún no está configurado, el dominio queda verificado y no se activa.

La función requiere secretos que **todavía no están configurados**:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ZONE_ID`
- opcional `CLOUDFLARE_CUSTOM_DOMAIN_ORIGIN` (default: `domains.yummypro.online`)

Si faltan, responde `cloudflare_not_configured` y no modifica un dominio como activo.

## Gateway versionado

Archivos:

- `infrastructure/custom-domain-gateway/worker.js`
- `infrastructure/custom-domain-gateway/README.md`

El Worker resuelve el negocio por `custom_domain` usando la API pública/RLS de Producción y enruta:

- Restaurante / Retail / Profesionales → `menu.yummypro.online`
- Streaming → `streaming.yummypro.online/catalogo`

Este código está versionado pero **no desplegado**.

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
2. Configurar/desplegar el Worker `custom-domain-gateway` en Cloudflare.
3. Configurar `domains.yummypro.online` como fallback/gateway de Cloudflare for SaaS.
4. Cargar de forma segura los secretos Cloudflare requeridos por `provision-business-domain`.
5. Probar con **un dominio de pruebas real** el ciclo completo: solicitud → TXT/CNAME → verificación → Custom Hostname → SSL → active → carga pública.
6. Ejecutar Auditor/quality/smoke end-to-end.
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


## Verificación de permisos realizada

En Supabase Staging se comprobó:

- normalización: `https://WWW.Example.com/path` → `www.example.com`;
- `anon` NO puede ejecutar get/request de dominio;
- `authenticated` SÍ puede ejecutar get/request, pero las funciones validan `can_manage_restaurant`;
- `authenticated` NO puede ejecutar `service_activate_business_custom_domain`;
- `service_role` SÍ puede ejecutar la activación;
- al cierre de esta etapa no se insertaron dominios de negocio reales en Staging (`business_custom_domains` tenía 0 filas).


## Corrección del panel Dominio en las cuatro verticales · 2026-09-28

Se detectó en Restaurante Pruebas que la pestaña **Dominio** podía quedarse indefinidamente en `Cargando…`.

### Causa real

El módulo de dominios comprobaba:

```js
window.sb
window.currentRestaurant
```

pero la aplicación mantiene `sb` y `currentRestaurant` como bindings globales del script, no como propiedades de `window`. Por esa razón la función retornaba antes de ejecutar el RPC `get_business_custom_domain`.

### Patrón correcto

Las cuatro verticales deben usar:

```js
if(!panel || !sb || !currentRestaurant) return;
```

y las operaciones de dominio deben tener timeout de **15 segundos** y estado de error con botón **Reintentar**.

También se debe volver a cargar el estado si la pestaña Dominio ya está activa al restaurar Configuración y se debe incrementar el query de versión del `professional.js` después de modificarlo para invalidar caché.

### Restaurante

Corrección validada previamente en Pruebas:

- HEAD funcional Staging: `4f394422beb9e079e25507db3672cd25b31c4fa8`
- usa el módulo publicado `panel/professional-domain-fix.js?v=2`;
- panel validado manualmente mostrando:
  `Todavía no conectaste un dominio…`;
- Producción no fue modificada.

### Retail

Corrección aplicada a `staging`:

- HEAD validado: `64aad23c817a548aa4890134801af36d59fcbbf8`
- `professional.js?v=2534`
- timeout 15 s ✅
- guard con `sb/currentRestaurant` reales ✅
- error + Reintentar ✅
- recarga si Dominio está activo ✅
- Quality ✅
- Smoke GitHub Pages Pruebas ✅
- Environment guard ✅
- Publicación Retail Pruebas ✅
- `main` no modificado.

### Profesionales

Corrección aplicada a `staging`:

- HEAD validado: `632ab6015fae44d95c074de17da939bcbfac115b`
- `professional.js?v=2535`
- timeout 15 s ✅
- guard con `sb/currentRestaurant` reales ✅
- error + Reintentar ✅
- recarga si Dominio está activo ✅
- Quality ✅
- Smoke GitHub Pages Pruebas ✅
- Environment guard ✅
- Publicación Profesionales Pruebas ✅
- `main` no modificado.

### Streaming

Corrección aplicada a `staging`:

- HEAD validado: `593e00683c2610e56ee3f63e02ce590ea43e1864`
- `professional.js?v=2534`
- timeout 15 s ✅
- guard con `sb/currentRestaurant` reales ✅
- error + Reintentar ✅
- recarga si Dominio está activo ✅
- Quality ✅
- Smoke GitHub Pages Pruebas ✅
- Environment guard ✅
- Publicación Streaming Pruebas ✅
- `main` no modificado.

Durante la corrección aparecieron dos tipos de fallos de CI que ya quedaron resueltos:

1. una inserción automática dejó secuencias literales `\\n` en el JS y produjo error de sintaxis; se corrigió antes de validar;
2. los tests estáticos conservaban versiones de caché antiguas y Streaming tenía `v1.2.15` hardcodeado aunque `VERSION` ya era `1.2.16`. Retail/Profesionales se alinearon con el query vigente y Streaming pasó a leer `VERSION` dinámicamente tanto en static check como en E2E.

### Regla para futuras IAs

No considerar completa una corrección del panel Dominio solo porque la publicación de Pruebas terminó. Confirmar sobre el **mismo HEAD**:

1. Quality = success.
2. Smoke = success.
3. Environment guard = success.
4. repositorio `*-pruebas` publicado con el SHA exacto.
5. `main` continúa intacto hasta release autorizado.

El siguiente trabajo de dominios personalizados continúa siendo Cloudflare/gateway + prueba DNS/SSL end-to-end. Esta corrección de UI no activa por sí sola dominios reales.
