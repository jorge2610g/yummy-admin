const token = process.env.CLOUDFLARE_API_TOKEN || "";
const zoneName = process.env.CLOUDFLARE_ZONE_NAME || "yummypro.online";

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

console.log(JSON.stringify({
  ok: true,
  reference_host: referenceHost,
  repaired,
}, null, 2));
