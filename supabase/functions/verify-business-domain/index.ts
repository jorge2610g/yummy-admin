import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function dnsAnswers(name: string, type: "TXT" | "CNAME") {
  const url = "https://dns.google/resolve?name=" + encodeURIComponent(name) + "&type=" + type;
  const res = await fetch(url, { headers: { accept: "application/dns-json" } });
  if (!res.ok) throw new Error("DNS HTTP " + res.status);
  const data = await res.json();
  return Array.isArray(data?.Answer) ? data.Answer.map((x: any) => String(x?.data || "")) : [];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "No autorizado" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: userData, error: userError } = await userClient.auth.getUser(token);
    if (userError || !userData?.user) return json({ error: "Sesión inválida" }, 401);

    const body = await req.json().catch(() => ({}));
    const restaurantId = Number(body?.restaurant_id || 0);
    if (!Number.isFinite(restaurantId) || restaurantId <= 0) {
      return json({ error: "Negocio inválido" }, 400);
    }

    const { data: state, error: stateError } = await userClient.rpc("get_business_custom_domain", {
      p_restaurant_id: restaurantId,
    });
    if (stateError) return json({ error: stateError.message || "No autorizado" }, 403);

    const pending = state?.pending || null;
    if (!pending?.hostname) return json({ error: "No hay un dominio pendiente de verificación" }, 400);

    const hostname = String(pending.hostname).toLowerCase();
    const txtName = String(pending.verification_record_name || "_yummypro." + hostname);
    const txtValue = String(pending.verification_record_value || "");
    const cnameTarget = String(pending.cname_target || "domains.yummypro.online").replace(/\.$/, "").toLowerCase();

    const [txtAnswers, cnameAnswers] = await Promise.all([
      dnsAnswers(txtName, "TXT").catch(() => []),
      dnsAnswers(hostname, "CNAME").catch(() => []),
    ]);

    const txtVerified = txtAnswers.some((v: string) => v.replace(/^"|"$/g, "").includes(txtValue));
    const cnameVerified = cnameAnswers.some((v: string) => v.replace(/\.$/, "").toLowerCase() === cnameTarget);
    const verified = txtVerified && cnameVerified;

    const update: Record<string, unknown> = {
      last_checked_at: new Date().toISOString(),
      last_error: verified ? null : [
        txtVerified ? null : "TXT pendiente",
        cnameVerified ? null : "CNAME pendiente",
      ].filter(Boolean).join(" · "),
    };
    if (verified) {
      update.status = "dns_verified";
      update.verified_at = new Date().toISOString();
    } else {
      update.status = "pending_dns";
    }

    const { error: updateError } = await adminClient
      .from("business_custom_domains")
      .update(update)
      .eq("restaurant_id", restaurantId)
      .eq("hostname", hostname)
      .in("status", ["pending_dns", "dns_verified", "failed"]);
    if (updateError) throw updateError;

    return json({
      ok: true,
      verified,
      hostname,
      txt: { name: txtName, expected: txtValue, answers: txtAnswers, verified: txtVerified },
      cname: { name: hostname, expected: cnameTarget, answers: cnameAnswers, verified: cnameVerified },
      next_status: verified ? "dns_verified" : "pending_dns",
      note: verified
        ? "DNS verificado. Falta aprovisionar HTTPS/enrutamiento con el proveedor de dominios."
        : "Los DNS todavía no coinciden. La propagación puede tardar.",
    });
  } catch (error) {
    console.error("verify-business-domain", error);
    return json({ error: String((error as Error)?.message || error) }, 500);
  }
});