const hosts = [
  "https://admin.yummypro.online/",
  "https://web.yummypro.online/",
  "https://retail.yummypro.online/",
  "https://pro.yummypro.online/",
  "https://streaming.yummypro.online/",
  "https://menu.yummypro.online/",
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function probe(url) {
  try {
    const response = await fetch(url, { redirect: "manual" });
    const body = response.status >= 500 ? (await response.text()).replace(/\s+/g, " ").slice(0, 240) : "";
    return {
      status: response.status,
      server: response.headers.get("server") || "",
      ray: response.headers.get("cf-ray") || "",
      location: response.headers.get("location") || "",
      body,
    };
  } catch (error) {
    return { status: 0, error: String(error?.message || error) };
  }
}

for (const url of hosts) {
  let last = null;
  let ok = false;

  for (let attempt = 1; attempt <= 18; attempt += 1) {
    last = await probe(url);
    console.log("Official hostname probe", { url, attempt, ...last });

    if (last.status > 0 && last.status < 500) {
      ok = true;
      break;
    }

    if (attempt < 18) await sleep(10000);
  }

  if (!ok) {
    throw new Error("Official hostname is still unhealthy after retries: " + url + " last=" + JSON.stringify(last));
  }
}

console.log("All official YummyPro hostnames are reachable without 5xx.");
