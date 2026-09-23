import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Copia de referencia de la función desplegada el 2026-09-23.
// Los secretos se leen de variables de entorno de Supabase; nunca deben escribirse aquí.
const SUPABASE_URL=Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY=Deno.env.get("RESEND_API_KEY")!;
const admin=createClient(SUPABASE_URL,SERVICE_ROLE,{auth:{persistSession:false}});
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const esc=(v:any)=>String(v??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));
const json=(body:any,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});

async function recipients(){
  const {data}=await admin.from("admin_users").select("email").not("email","is",null);
  return [...new Set((data||[]).map((x:any)=>String(x.email||"").trim().toLowerCase()).filter((x:string)=>x.includes("@")))];
}
async function alreadySent(key:string){
  const {data}=await admin.from("observability_alert_log").select("id").eq("alert_key",key).maybeSingle();
  return !!data;
}
async function remember(key:string,type:string,count:number,metadata:any){
  await admin.from("observability_alert_log").insert({alert_key:key,alert_type:type,recipient_count:count,metadata});
}
async function sendMail(to:string[],subject:string,html:string,key:string){
  const res=await fetch("https://api.resend.com/emails",{
    method:"POST",
    headers:{"Authorization":"Bearer "+RESEND_API_KEY,"Content-Type":"application/json","Idempotency-Key":key.slice(0,250)},
    body:JSON.stringify({from:"YummyPro <notificaciones@yummypro.online>",to,subject,html})
  });
  const out=await res.json().catch(()=>({}));
  if(!res.ok)throw new Error("Resend "+res.status+": "+JSON.stringify(out).slice(0,500));
  return out;
}

Deno.serve(async(req)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(req.method!=="POST")return json({error:"Method not allowed"},405);
  try{
    const body=await req.json().catch(()=>({}));
    const kind=body?.kind==="report"?"report":"error";
    const to=await recipients();
    if(!to.length)return json({ok:true,skipped:"no_admin_recipients"});

    if(kind==="report"){
      const since=new Date(Date.now()-15*60*1000).toISOString();
      const {data:reports,error}=await admin.from("user_issue_reports")
        .select("id,created_at,app_context,restaurant_id,title,description,status")
        .in("status",["open","reviewing"]).gte("created_at",since)
        .order("created_at",{ascending:false}).limit(10);
      if(error)throw error;
      for(const report of reports||[]){
        const key="issue-report:"+report.id;
        if(await alreadySent(key))continue;
        let restaurantName="Sin restaurante";
        if(report.restaurant_id){
          const {data:r}=await admin.from("restaurants").select("name").eq("id",report.restaurant_id).maybeSingle();
          if(r?.name)restaurantName=r.name;
        }
        const subject="YummyPro · Nuevo reporte de problema";
        const html=`<h2>⚠ Nuevo reporte de problema</h2><p><b>Restaurante:</b> ${esc(restaurantName)}</p><p><b>Origen:</b> ${esc(report.app_context)}</p><p><b>Título:</b> ${esc(report.title)}</p><p>${esc(report.description)}</p><p>Revisa Administrador → Observabilidad.</p>`;
        await sendMail(to,subject,html,key);
        await remember(key,"report",to.length,{report_id:report.id,restaurant_id:report.restaurant_id});
        return json({ok:true,sent:true,type:"report",report_id:report.id});
      }
      return json({ok:true,skipped:"no_new_report"});
    }

    const since=new Date(Date.now()-15*60*1000).toISOString();
    const {data:errors,error}=await admin.from("app_errors")
      .select("id,occurred_at,app_context,category,error_code,message,severity,restaurant_id")
      .eq("is_user_error",false).eq("resolved",false).gte("occurred_at",since)
      .order("occurred_at",{ascending:false}).limit(300);
    if(error)throw error;
    const rows=errors||[];
    if(rows.length<3)return json({ok:true,skipped:"below_threshold",count:rows.length});

    const groups=new Map<string,{count:number,context:string,category:string,code:string,last:string,message:string}>();
    for(const e of rows){
      const code=String(e.error_code||"sin_codigo");
      const k=[e.app_context,e.category,code].join("|");
      const g=groups.get(k)||{count:0,context:String(e.app_context||""),category:String(e.category||""),code,last:String(e.occurred_at||""),message:String(e.message||"")};
      g.count++; if(String(e.occurred_at||"")>g.last){g.last=String(e.occurred_at||"");g.message=String(e.message||"")}
      groups.set(k,g);
    }
    const top=[...groups.values()].sort((a,b)=>b.count-a.count).slice(0,6);
    const hour=new Date().toISOString().slice(0,13);
    const signature=top.slice(0,3).map(x=>x.context+"-"+x.code).join("_").replace(/[^a-zA-Z0-9_-]/g,"").slice(0,160);
    const key="system-errors:"+hour+":"+signature;
    if(await alreadySent(key))return json({ok:true,skipped:"deduplicated",count:rows.length});

    const subject="YummyPro · Alerta de fallos técnicos ("+rows.length+" en 15 min)";
    const list=top.map(x=>`<li><b>${esc(x.context)} · ${esc(x.code)}</b> — ${x.count} veces<br>${esc(x.message).slice(0,250)}</li>`).join("");
    const html=`<h2>🔴 YummyPro detectó fallos repetidos</h2><p>Se registraron <b>${rows.length} fallos técnicos</b> durante los últimos 15 minutos. Los errores de uso no cuentan para esta alerta.</p><ul>${list}</ul><p>Revisa Administrador → Observabilidad.</p>`;
    await sendMail(to,subject,html,key);
    await remember(key,"system_error",to.length,{count:rows.length,top});
    return json({ok:true,sent:true,type:"system_error",count:rows.length});
  }catch(e){
    return json({error:e instanceof Error?e.message:String(e)},500);
  }
});
