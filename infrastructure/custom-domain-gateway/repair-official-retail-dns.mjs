const token = process.env.CLOUDFLARE_API_TOKEN || "";
const zoneName = process.env.CLOUDFLARE_ZONE_NAME || "yummypro.online";
const stagingWorker = process.env.CLOUDFLARE_STAGING_WORKER || "yummypro-custom-domain-staging";

if (!token) throw new Error("CLOUDFLARE_API_TOKEN is required");

async function api(path, { method = "GET", body = null } = {}) {
  const res = await fetch("https://api.cloudflare.com/client/v4" + path, {
    method,
    headers: {
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
    },
    body: body == null ? undefined : JSON.stringify(body),
  });
  const payload = await res.json().catch(() => ({}));
  if (!res.ok || payload?.success === false) {
    const message = payload?.errors?.map((x) => x?.message).filter(Boolean).join(" · ");
    throw new Error(message || ("Cloudflare HTTP " + res.status));
  }
  return payload;
}

const zones = (await api("/zones?name=" + encodeURIComponent(zoneName) + "&status=active&per_page=5")).result || [];
if (zones.length !== 1) throw new Error("Expected exactly one active Cloudflare zone for " + zoneName);
const zoneId = String(zones[0]?.id || "");
if (!zoneId) throw new Error("Cloudflare zone id missing");

async function dnsFor(host) {
  const payload = await api("/zones/" + encodeURIComponent(zoneId) + "/dns_records?name=" + encodeURIComponent(host) + "&per_page=20");
  return Array.isArray(payload?.result) ? payload.result : [];
}

const referenceHost = "web." + zoneName;
const referenceRows = await dnsFor(referenceHost);
if (referenceRows.length !== 1 || String(referenceRows[0]?.type || "") !== "CNAME") {
  throw new Error("Safety stop: " + referenceHost + " must have exactly one CNAME before repairing other official hosts");
}

const reference = {
  content: String(referenceRows[0]?.content || "").toLowerCase(),
  proxied: referenceRows[0]?.proxied === true,
};
if (!reference.content) throw new Error("Safety stop: reference CNAME target is empty");

console.log("Official DNS reference:", {
  host: referenceHost,
  type: "CNAME",
  content: reference.content,
  proxied: reference.proxied,
});

const officialHosts = [
  "admin." + zoneName,
  "retail." + zoneName,
  "pro." + zoneName,
  "streaming." + zoneName,
  "menu." + zoneName,
];

const repaired = [];
for (const host of officialHosts) {
  const rows = await dnsFor(host);

  if (rows.length) {
    console.log("Official hostname already has DNS; leaving unchanged:", {
      host,
      records: rows.map((row) => ({
        type: row?.type,
        content: row?.content,
        proxied: row?.proxied,
      })),
    });
    continue;
  }

  await api("/zones/" + encodeURIComponent(zoneId) + "/dns_records", {
    method: "POST",
    body: {
      type: "CNAME",
      name: host,
      content: reference.content,
      ttl: 1,
      proxied: reference.proxied,
      comment: "YummyPro official GitHub Pages hostname repaired from web.yummypro.online",
    },
  });

  repaired.push(host);
  console.log("Repaired missing official hostname:", {
    host,
    type: "CNAME",
    content: reference.content,
    proxied: reference.proxied,
  });
}

// Official production hostnames are served directly by GitHub Pages.
// No Cloudflare Worker route or SaaS Custom Hostname may intercept them.
const routePayload = await api("/zones/" + encodeURIComponent(zoneId) + "/workers/routes");
const routes = Array.isArray(routePayload?.result) ? routePayload.result : [];
const reservedHosts = [
  "admin." + zoneName,
  "web." + zoneName,
  "retail." + zoneName,
  "pro." + zoneName,
  "streaming." + zoneName,
  "menu." + zoneName,
];

const removedRoutes = [];
for (const route of routes) {
  const pattern = String(route?.pattern || "").toLowerCase();
  const script = String(route?.script || "");
  const ownsReservedHost = reservedHosts.some((host) => {
    const h = host.toLowerCase();
    return pattern === h + "/*" ||
      pattern === "*://" + h + "/*" ||
      pattern === "https://" + h + "/*" ||
      pattern === "http://" + h + "/*";
  });

  if (ownsReservedHost) {
    const id = String(route?.id || "");
    if (!id) throw new Error("Safety stop: Worker route on official hostname has no id");
    await api("/zones/" + encodeURIComponent(zoneId) + "/workers/routes/" + encodeURIComponent(id), {
      method: "DELETE",
    });
    removedRoutes.push({ pattern, script });
    console.log("Removed Worker route from official production hostname:", { pattern, script });
  }
}

const hostPayload = await api("/zones/" + encodeURIComponent(zoneId) + "/custom_hostnames?per_page=100");
const customHosts = Array.isArray(hostPayload?.result) ? hostPayload.result : [];
const removedCustomHostnames = [];
for (const row of customHosts) {
  const hostname = String(row?.hostname || "").toLowerCase();
  if (!reservedHosts.includes(hostname)) continue;

  const id = String(row?.id || "");
  if (!id) throw new Error("Safety stop: Custom Hostname on official hostname has no id");
  await api("/zones/" + encodeURIComponent(zoneId) + "/custom_hostnames/" + encodeURIComponent(id), {
    method: "DELETE",
  });
  removedCustomHostnames.push(hostname);
  console.log("Removed Cloudflare for SaaS Custom Hostname from official production hostname:", { hostname });
}

console.log(JSON.stringify({
  ok: true,
  reference_host: referenceHost,
  repaired,
  removed_worker_routes: removedRoutes,
  removed_custom_hostnames: removedCustomHostnames,
}, null, 2));
