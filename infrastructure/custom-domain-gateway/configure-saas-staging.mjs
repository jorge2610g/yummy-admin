const token=process.env.CLOUDFLARE_API_TOKEN||"";
const zoneName=process.env.CLOUDFLARE_ZONE_NAME||"yummypro.online";
const fallbackHost=process.env.CLOUDFLARE_STAGING_FALLBACK||"domains-pruebas.yummypro.online";
const stagingWorker=process.env.CLOUDFLARE_STAGING_WORKER||"yummypro-custom-domain-staging";

if(!token)throw new Error("CLOUDFLARE_API_TOKEN is required");

async function api(path,{method="GET",body=null,allowFailure=false}={}){
  const res=await fetch("https://api.cloudflare.com/client/v4"+path,{
    method,
    headers:{
      Authorization:"Bearer "+token,
      "Content-Type":"application/json",
    },
    body:body==null?undefined:JSON.stringify(body),
  });
  const payload=await res.json().catch(()=>({}));
  if((!res.ok||payload?.success===false)&&!allowFailure){
    throw new Error(payload?.errors?.map(x=>x?.message).filter(Boolean).join(" · ")||("Cloudflare HTTP "+res.status));
  }
  return {res,payload};
}

const zones=(await api("/zones?name="+encodeURIComponent(zoneName)+"&status=active&per_page=5")).payload?.result||[];
if(zones.length!==1)throw new Error("Expected exactly one active Cloudflare zone for "+zoneName+"; found "+zones.length);
const zoneId=String(zones[0].id||"");
if(!zoneId)throw new Error("Cloudflare zone id missing");

console.log("Cloudflare zone resolved:",zoneName);

// Safety: staging must never own the zone-wide wildcard route.
const routeRows=(await api("/zones/"+encodeURIComponent(zoneId)+"/workers/routes")).payload?.result||[];
const dangerous=routeRows.find(row=>String(row?.pattern||"")==="*/*"&&String(row?.script||"")===stagingWorker);
if(dangerous)throw new Error("Safety stop: staging Worker is attached to * /*. Remove that wildcard route before continuing.");

// Ensure originless proxied fallback DNS exists, without replacing unexpected DNS.
const dnsQuery="/zones/"+encodeURIComponent(zoneId)+"/dns_records?name="+encodeURIComponent(fallbackHost)+"&per_page=20";
const dnsRows=(await api(dnsQuery)).payload?.result||[];
if(!dnsRows.length){
  await api("/zones/"+encodeURIComponent(zoneId)+"/dns_records",{
    method:"POST",
    body:{type:"AAAA",name:fallbackHost,content:"100::",ttl:1,proxied:true,comment:"YummyPro custom domains staging fallback"},
  });
  console.log("Created proxied originless fallback DNS:",fallbackHost);
}else{
  const expected=dnsRows.find(row=>String(row?.type||"")==="AAAA"&&String(row?.content||"")==="100::"&&row?.proxied===true);
  if(!expected){
    const summary=dnsRows.map(row=>({id:row?.id,type:row?.type,name:row?.name,content:row?.content,proxied:row?.proxied,ttl:row?.ttl,comment:row?.comment||""}));
    throw new Error("Safety stop: "+fallbackHost+" already has unexpected DNS. Existing record was not modified. Existing DNS: "+JSON.stringify(summary));
  }
  console.log("Fallback DNS already valid:",fallbackHost);
}

// Read existing custom hostnames before touching a zone-level fallback.
const hostRows=(await api("/zones/"+encodeURIComponent(zoneId)+"/custom_hostnames?per_page=50")).payload?.result||[];

const fallbackResponse=await api(
  "/zones/"+encodeURIComponent(zoneId)+"/custom_hostnames/fallback_origin",
  {allowFailure:true}
);
const fallbackResult=fallbackResponse.payload?.result||null;
const currentOrigin=String(fallbackResult?.origin||"").toLowerCase();

if(currentOrigin&&currentOrigin!==fallbackHost.toLowerCase()){
  throw new Error("Safety stop: Cloudflare already has a different SaaS fallback origin ("+currentOrigin+"). It was not replaced.");
}

if(!currentOrigin){
  if(hostRows.length){
    throw new Error("Safety stop: custom hostnames already exist but no fallback origin was readable. Review Cloudflare manually before changing it.");
  }
  const updated=(await api(
    "/zones/"+encodeURIComponent(zoneId)+"/custom_hostnames/fallback_origin",
    {method:"PUT",body:{origin:fallbackHost}}
  )).payload?.result||{};
  console.log("Staging fallback origin requested:",String(updated?.origin||fallbackHost),"status:",String(updated?.status||"unknown"));
}else{
  console.log("Fallback origin already points to staging target; status:",String(fallbackResult?.status||"unknown"));
}

console.log(JSON.stringify({
  ok:true,
  zone_name:zoneName,
  fallback_host:fallbackHost,
  custom_hostnames_visible:hostRows.length,
  staging_worker:stagingWorker,
  wildcard_route_created:false,
},null,2));
