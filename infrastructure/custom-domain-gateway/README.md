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
