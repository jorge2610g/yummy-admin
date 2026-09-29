const token = process.env.CLOUDFLARE_API_TOKEN || "";
const zoneName = process.env.CLOUDFLARE_ZONE_NAME || "yummypro.online";
const targetHost = "retail." + zoneName;
const peerHosts = [
  "web." + zoneName,
  "pro." + zoneName,
  "streaming." + zoneName,
  "menu." + zoneName,
];

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

const existing = await dnsFor(targetHost);
if (existing.length) {
  const valid = existing.length === 1 && String(existing[0]?.type || "") === "CNAME";
  if (!valid) {
    const summary = existing.map((row) => ({
      type: row?.type,
      name: row?.name,
      content: row?.content,
      proxied: row?.proxied,
    }));
    throw new Error("Safety stop: " + targetHost + " has unexpected DNS: " + JSON.stringify(summary));
  }
  console.log("Official Retail DNS already exists:", {
    type: existing[0].type,
    name: existing[0].name,
    content: existing[0].content,
    proxied: existing[0].proxied,
  });
  process.exit(0);
}

const peers = [];
for (const host of peerHosts) {
  const rows = await dnsFor(host);
  if (rows.length !== 1 || String(rows[0]?.type || "") !== "CNAME") {
    throw new Error("Safety stop: expected one CNAME for peer host " + host + " but found " + rows.length);
  }
  peers.push({
    host,
    content: String(rows[0]?.content || "").toLowerCase(),
    proxied: rows[0]?.proxied === true,
  });
}

const contents = [...new Set(peers.map((row) => row.content))];
const proxyModes = [...new Set(peers.map((row) => row.proxied))];
if (contents.length !== 1 || !contents[0]) {
  throw new Error("Safety stop: official peer hostnames do not share one CNAME target: " + JSON.stringify(peers));
}
if (proxyModes.length !== 1) {
  throw new Error("Safety stop: official peer hostnames do not share one Cloudflare proxy mode: " + JSON.stringify(peers));
}

await api("/zones/" + encodeURIComponent(zoneId) + "/dns_records", {
  method: "POST",
  body: {
    type: "CNAME",
    name: targetHost,
    content: contents[0],
    ttl: 1,
    proxied: proxyModes[0],
    comment: "YummyPro official Retail hostname repaired from verified platform DNS peers",
  },
});

console.log("Repaired missing official Retail DNS:", {
  name: targetHost,
  type: "CNAME",
  content: contents[0],
  proxied: proxyModes[0],
});
