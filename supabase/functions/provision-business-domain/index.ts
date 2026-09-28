import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const corsHeaders={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":"POST, OPTIONS",
};

function json(body:unknown,status=200){
  return new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json"}});
}

async function cfFetch(path:string,init:RequestInit,token:string){
  const res=await fetch("https://api.cloudflare.com/client/v4"+path,{
    ...init,
    headers:{
      Authorization:"Bearer "+token,
      "Content-Type":"application/json",
      ...(init.headers||{}),
    },
  });
  const payload=await res.json().catch(()=>({}));
  if(!res.ok||payload?.success===false){
    throw new Error(payload?.errors?.[0]?.message||("Cloudflare HTTP "+res.status));
  }
  return payload;
}

Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST")return json({error:"Método no permitido"},405);

  try{
    const authHeader=req.headers.get("Authorization")||"";
    const token=authHeader.replace(/^Bearer\s+/i,"");
    if(!token)return json({error:"No autorizado"},401);

    const supabaseUrl=Deno.env.get("SUPABASE_URL")||"";
    const anonKey=Deno.env.get("SUPABASE_ANON_KEY")||Deno.env.get("SUPABASE_PUBLISHABLE_KEY")||"";
    const serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
    const cfToken=Deno.env.get("CLOUDFLARE_API_TOKEN")||"";
    const cfZone=Deno.env.get("CLOUDFLARE_ZONE_ID")||"";
    const originHost=Deno.env.get("CLOUDFLARE_CUSTOM_DOMAIN_ORIGIN")||"domains.yummypro.online";

    if(!cfToken||!cfZone){
      return json({error:"Cloudflare todavía no está configurado en Staging",code:"cloudflare_not_configured"},503);
    }

    const userClient=createClient(supabaseUrl,anonKey,{
      global:{headers:{Authorization:authHeader}},
      auth:{persistSession:false,autoRefreshToken:false},
    });
    const adminClient=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});

    const {data:userData,error:userError}=await userClient.auth.getUser(token);
    if(userError||!userData?.user)return json({error:"Sesión inválida"},401);

    const body=await req.json().catch(()=>({}));
    const restaurantId=Number(body?.restaurant_id||0);
    if(!Number.isFinite(restaurantId)||restaurantId<=0)return json({error:"Negocio inválido"},400);

    const {data:state,error:stateError}=await userClient.rpc("get_business_custom_domain",{p_restaurant_id:restaurantId});
    if(stateError)return json({error:stateError.message||"No autorizado"},403);

    const pending=state?.pending||null;
    if(!pending?.hostname)return json({error:"No hay dominio pendiente"},400);
    if(!["dns_verified","provisioning"].includes(String(pending.status))){
      return json({error:"Primero debes verificar los registros DNS",status:pending.status},409);
    }

    const hostname=String(pending.hostname).toLowerCase();
    const {data:domainRow,error:domainError}=await adminClient
      .from("business_custom_domains")
      .select("id,provider_hostname_id,status,ssl_status")
      .eq("restaurant_id",restaurantId)
      .eq("hostname",hostname)
      .in("status",["dns_verified","provisioning"])
      .maybeSingle();
    if(domainError)throw domainError;
    if(!domainRow)return json({error:"No se encontró la solicitud de dominio"},404);

    let providerId=String(domainRow.provider_hostname_id||"");
    let cfResult:any;

    if(!providerId){
      const created=await cfFetch("/zones/"+encodeURIComponent(cfZone)+"/custom_hostnames",{
        method:"POST",
        body:JSON.stringify({
          hostname,
          custom_origin_server:originHost,
          custom_origin_sni:originHost,
          ssl:{method:"txt",type:"dv"},
        }),
      },cfToken);
      cfResult=created?.result;
      providerId=String(cfResult?.id||"");
      if(!providerId)throw new Error("Cloudflare no devolvió id del Custom Hostname");

      const {error:updateError}=await adminClient.from("business_custom_domains").update({
        status:"provisioning",
        ssl_status:"initializing",
        provider_hostname_id:providerId,
        last_checked_at:new Date().toISOString(),
        last_error:null,
      }).eq("id",domainRow.id);
      if(updateError)throw updateError;
    }else{
      const checked=await cfFetch("/zones/"+encodeURIComponent(cfZone)+"/custom_hostnames/"+encodeURIComponent(providerId),{
        method:"GET",
      },cfToken);
      cfResult=checked?.result;
    }

    const hostnameStatus=String(cfResult?.status||"pending");
    const sslStatus=String(cfResult?.ssl?.status||"pending");
    const ready=hostnameStatus==="active"&&sslStatus==="active";

    if(ready){
      const {data:activated,error:activateError}=await adminClient.rpc("service_activate_business_custom_domain",{
        p_restaurant_id:restaurantId,
        p_hostname:hostname,
        p_provider_hostname_id:providerId,
      });
      if(activateError)throw activateError;
      return json({ok:true,ready:true,hostname,hostname_status:hostnameStatus,ssl_status:sslStatus,activated});
    }

    const {error:updateError}=await adminClient.from("business_custom_domains").update({
      status:"provisioning",
      ssl_status:sslStatus==="active"?"active":"initializing",
      last_checked_at:new Date().toISOString(),
      last_error:null,
    }).eq("id",domainRow.id);
    if(updateError)throw updateError;

    return json({
      ok:true,
      ready:false,
      hostname,
      hostname_status:hostnameStatus,
      ssl_status:sslStatus,
      provider_hostname_id:providerId,
      message:"Cloudflare todavía está aprovisionando el hostname o el certificado.",
    });
  }catch(error){
    console.error("provision-business-domain",error);
    return json({error:String((error as Error)?.message||error)},500);
  }
});