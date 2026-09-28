/**
 * YummyPro · Custom Domain Gateway
 *
 * Estado: blueprint listo para Cloudflare Workers.
 * NO contiene secretos ni está desplegado desde este repositorio.
 *
 * Variables requeridas:
 * - SUPABASE_URL=https://gulctljitzlwokqydigx.supabase.co
 * - SUPABASE_PUBLISHABLE_KEY=<publishable key de Producción>
 * - CLIENT_ORIGIN=https://menu.yummypro.online
 * - STREAMING_ORIGIN=https://streaming.yummypro.online
 */

const PLATFORM_HOSTS = new Set([
  "menu.yummypro.online",
  "streaming.yummypro.online",
  "domains.yummypro.online",
]);

function normalizeHost(host) {
  return String(host || "").trim().toLowerCase().replace(/:\d+$/, "").replace(/^www\./, "");
}

async function resolveBusiness(hostname, env) {
  const host = normalizeHost(hostname);
  if (!host || PLATFORM_HOSTS.has(host)) return null;

  const url = new URL("/rest/v1/restaurants", env.SUPABASE_URL);
  url.searchParams.set("select", "id,slug,business_type,custom_domain,active,subscription_status");
  url.searchParams.set("active", "eq.true");
  url.searchParams.set("custom_domain", "eq." + host);
  url.searchParams.set("limit", "1");

  const response = await fetch(url.toString(), {
    headers: {
      apikey: env.SUPABASE_PUBLISHABLE_KEY,
      Authorization: "Bearer " + env.SUPABASE_PUBLISHABLE_KEY,
      Accept: "application/json",
    },
    cf: { cacheTtl: 30, cacheEverything: true },
  });

  if (!response.ok) throw new Error("Supabase lookup HTTP " + response.status);
  const rows = await response.json();
  return Array.isArray(rows) && rows.length ? rows[0] : null;
}

function originTarget(requestUrl, business, env) {
  const incoming = new URL(requestUrl);
  const type = String(business?.business_type || "restaurant").toLowerCase();

  if (type === "streaming") {
    const origin = new URL(env.STREAMING_ORIGIN || "https://streaming.yummypro.online");
    const relative = incoming.pathname === "/" ? "/" : incoming.pathname;
    origin.pathname = "/catalogo" + (relative.startsWith("/") ? relative : "/" + relative);
    origin.search = incoming.search;
    return origin;
  }

  const origin = new URL(env.CLIENT_ORIGIN || "https://menu.yummypro.online");
  origin.pathname = incoming.pathname;
  origin.search = incoming.search;
  return origin;
}

function copyRequest(request, target) {
  const headers = new Headers(request.headers);
  // El origin oficial no debe recibir el Host del dominio del cliente.
  headers.delete("host");
  // Conservamos el dominio del cliente solo como diagnóstico, nunca como autorización.
  headers.set("x-yummy-custom-host", new URL(request.url).hostname);

  return new Request(target.toString(), {
    method: request.method,
    headers,
    body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
    redirect: "manual",
  });
}

function withGatewayHeaders(response) {
  const headers = new Headers(response.headers);
  headers.set("x-yummy-domain-gateway", "1");
  headers.set("x-content-type-options", "nosniff");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export default {
  async fetch(request, env) {
    try {
      if (!env.SUPABASE_URL || !env.SUPABASE_PUBLISHABLE_KEY) {
        return new Response("Gateway no configurado", { status: 503 });
      }

      const incoming = new URL(request.url);
      const business = await resolveBusiness(incoming.hostname, env);

      if (!business) {
        return new Response("Dominio no vinculado a YummyPro", {
          status: 404,
          headers: { "content-type": "text/plain; charset=utf-8" },
        });
      }

      const target = originTarget(request.url, business, env);
      const upstream = await fetch(copyRequest(request, target));
      return withGatewayHeaders(upstream);
    } catch (error) {
      console.error("custom-domain-gateway", error);
      return new Response("No se pudo cargar este dominio", {
        status: 502,
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }
  },
};
