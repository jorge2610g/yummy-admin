# Custom Domain Gateway · Cloudflare

Estado: **código versionado, no desplegado**.

Este directorio contiene el gateway previsto para recibir los dominios personalizados de los negocios YummyPro.

## Por qué existe

GitHub Pages sirve correctamente los hostnames oficiales de YummyPro, pero no es la capa multi-tenant adecuada para aceptar hostnames arbitrarios de clientes. Cloudflare for SaaS / Custom Hostnames se usará delante de las aplicaciones públicas.

Flujo previsto:

```
www.negocio.com
      │
      ▼
Cloudflare Custom Hostname + SSL
      │
      ▼
domains.yummypro.online / Worker
      │
      ├─ Restaurante / Retail / Profesional → menu.yummypro.online
      └─ Streaming                       → streaming.yummypro.online/catalogo
```

El navegador del cliente conserva `www.negocio.com`. El Worker solo obtiene los archivos desde el origin oficial. La aplicación pública resuelve el negocio usando `location.hostname` + `restaurants.custom_domain`.

## Archivo

`worker.js`

No contiene credenciales.

Bindings/variables requeridos:

- `SUPABASE_URL` = URL de Supabase Producción.
- `SUPABASE_PUBLISHABLE_KEY` = publishable key de Producción. No usar service role.
- `CLIENT_ORIGIN` = `https://menu.yummypro.online`
- `STREAMING_ORIGIN` = `https://streaming.yummypro.online`

## Cloudflare pendiente

Antes de desplegar:

1. Tener la zona de `yummypro.online` bajo Cloudflare.
2. Crear/configurar `domains.yummypro.online` como fallback/gateway de Cloudflare for SaaS.
3. Crear API Token dedicado con el mínimo permiso necesario para Custom Hostnames/SSL.
4. Desplegar este Worker.
5. Crear la función backend de aprovisionamiento de Custom Hostnames.
6. Esperar que Cloudflare reporte:
   - hostname status = `active`
   - ssl status = `active`
7. Recién después activar el dominio en YummyPro mediante `service_activate_business_custom_domain`.

## Seguridad

- No guardar el API Token Cloudflare en este repositorio.
- No usar service role en el Worker público.
- El Worker solo consulta negocios activos mediante la API pública protegida por RLS.
- La activación de `restaurants.custom_domain` está protegida por trigger en la base de datos.
- El dominio debe pasar TXT + CNAME antes de aprovisionarse.

## Pruebas mínimas antes de Producción

- dominio inexistente → 404
- dominio de Restaurante → menú correcto
- dominio de Retail → tienda correcta
- dominio Profesional → página/agenda correcta
- dominio Streaming → catálogo correcto
- rutas y assets relativos
- HTTPS válido
- `www` y hostname exacto
- dominio desactivado deja de resolver
- ningún hostname puede reclamar otro `restaurant_id`

Ver también `docs/CUSTOM_DOMAINS.md`.


## Estado Staging · 2026-09-28

La automatización de Staging ya está versionada:

- `wrangler.toml` despliega `yummypro-custom-domain-staging` primero a `workers.dev`.
- `.github/workflows/cloudflare-gateway-staging.yml` valida, despliega y comprueba `/__yummy_health`.
- `configure-saas-staging.mjs` prepara de forma conservadora el fallback `domains-pruebas.yummypro.online`.
- El script **no crea** la ruta global `*/*`.
- Para una prueba real, `provision-business-domain` crea una ruta Worker únicamente para el dominio de prueba después de que ese dominio haya pasado la verificación DNS.

### Único secreto nuevo requerido

GitHub Repository Secret:

`CLOUDFLARE_API_TOKEN`

No copiar el token a archivos ni commits.

`CLOUDFLARE_ACCOUNT_ID` es opcional. Si no existe, el workflow intenta resolverlo automáticamente cuando el token solo puede ver una cuenta. Si el token ve varias cuentas, el workflow se detiene sin modificar Cloudflare y pide ese ID explícito.

El workflow reutiliza el secreto existente `STAGING_DB_PASSWORD` para guardar el token cifrado en **Supabase Vault Staging** con el nombre `cloudflare_api_token`. El Edge Function `provision-business-domain` lo lee mediante una función accesible únicamente a `service_role`.

### Permisos mínimos previstos para el token Cloudflare

Para completar todo el flujo de Staging el token debe estar limitado a la cuenta/zona de YummyPro y permitir:

- Account: **Workers Scripts Write**.
- Account: **Account Settings Read** (para resolver la cuenta cuando no se proporciona `CLOUDFLARE_ACCOUNT_ID`).
- Zone `yummypro.online`: **Zone Read**.
- Zone `yummypro.online`: **DNS Write**.
- Zone `yummypro.online`: **SSL and Certificates Write**.
- Zone `yummypro.online`: **Workers Routes Write**.

No dar permisos de administración global que no sean necesarios.

### Bloqueo externo actual

El primer run de `Cloudflare Gateway Staging` llegó correctamente al paso de credenciales y se detuvo porque `CLOUDFLARE_API_TOKEN` todavía no existe en GitHub Secrets. No se ejecutó Wrangler, no se modificó DNS de Cloudflare y Producción quedó intacta.

Una vez agregado el secreto, volver a ejecutar el workflow. El flujo esperado es:

1. resolver cuenta;
2. cifrar el token en Supabase Vault Staging;
3. validar bundle;
4. desplegar Worker a `workers.dev`;
5. comprobar health;
6. crear/validar el fallback DNS originless de Pruebas;
7. configurar el fallback SaaS solo si no existe una configuración incompatible;
8. dejar pendiente un dominio real de prueba para TXT + CNAME + Custom Hostname + SSL.

### Seguridad de rutas

Cloudflare recomienda `*/*` para capturar todos los vanity domains de un SaaS. **No usar esa ruta durante esta etapa de Staging**, porque la zona `yummypro.online` también contiene los hostnames oficiales de Producción.

En Staging se usa una ruta específica por dominio real de prueba. El wildcard se evaluará únicamente durante un release de infraestructura autorizado y después de definir passthrough/exclusiones para los hostnames oficiales.
