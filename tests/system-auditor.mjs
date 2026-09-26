import { chromium } from "@playwright/test";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import path from "node:path";

const OUT="audit-results";
const TEST_HOST="jorge2610g.github.io";
const SUPABASE_URL=process.env.SUPABASE_TEST_URL||"https://wodqqheeesrelsbacmgx.supabase.co";
const SUPABASE_KEY=process.env.SUPABASE_TEST_KEY||"sb_publishable_yiuYVYAAwVLtzlTdEM1kUg_s1Z7BiyE";
const GEMINI_MODEL=process.env.GEMINI_MODEL||"gemini-3.5-flash";
const GROQ_MODEL=process.env.GROQ_MODEL||"openai/gpt-oss-20b";
const ENFORCE_AI=String(process.env.AI_AUDIT_ENFORCE||"false").toLowerCase()==="true";

const panelModules=[
  {key:"admin",label:"Admin",url:"https://jorge2610g.github.io/yummy-admin-pruebas/",auth:"admin"},
  {key:"restaurante",label:"Restaurante",url:"https://jorge2610g.github.io/yummy-restaurante-pruebas/",auth:"business"},
  {key:"retail",label:"Retail",url:"https://jorge2610g.github.io/yummy-retail-pruebas/",auth:"business"},
  {key:"profesionales",label:"Profesionales",url:"https://jorge2610g.github.io/yummy-profesionales-pruebas/",auth:"business"},
  {key:"streaming",label:"Streaming",url:"https://jorge2610g.github.io/yummy-streaming-pruebas/",auth:"business"}
];

const now=()=>new Date().toISOString();
const slugify=s=>String(s).toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"");

async function discoverPublicTargets(){
  try{
    const url=new URL("/rest/v1/restaurants",SUPABASE_URL);
    url.searchParams.set("select","id,slug,name,business_type,is_demo,active");
    url.searchParams.set("active","eq.true");
    url.searchParams.set("order","is_demo.desc,id.asc");
    url.searchParams.set("limit","200");
    const res=await fetch(url,{headers:{apikey:SUPABASE_KEY}});
    if(!res.ok)throw new Error("Supabase "+res.status);
    const rows=await res.json();
    const byType={};
    for(const row of Array.isArray(rows)?rows:[]){
      const raw=String(row.business_type||"restaurant").toLowerCase();
      const key=["supermarket","minimarket","retail"].includes(raw)?"retail":raw==="professional"?"professional":raw==="streaming"?"streaming":"restaurant";
      if(!byType[key])byType[key]=row;
    }
    return byType;
  }catch(error){return {__error:String(error?.message||error)}}
}

function publicModules(targets){
  const client="https://jorge2610g.github.io/yummy-cliente-pruebas/";
  const streaming="https://jorge2610g.github.io/yummy-streaming-pruebas/catalogo/";
  const list=[];
  for(const pair of [["restaurant","Cliente Restaurante"],["retail","Cliente Retail"],["professional","Cliente Profesionales"]]){
    const key=pair[0],label=pair[1],row=targets[key],url=new URL(client);
    if(row)url.searchParams.set("r",row.slug||String(row.id));
    list.push({key:"cliente-"+key,label,url:url.toString(),auth:null,expectSelector:!!row});
  }
  const row=targets.streaming,url=new URL(streaming);
  if(row)url.searchParams.set("business",String(row.id));
  list.push({key:"cliente-streaming",label:"Catálogo Streaming",url:url.toString(),auth:null,expectSelector:!!row});
  return list;
}

async function maybeLogin(page,auth){
  if(!auth)return {attempted:false};
  const email=auth==="admin"?process.env.ADMIN_TEST_EMAIL:process.env.RESTAURANT_TEST_EMAIL;
  const password=auth==="admin"?process.env.ADMIN_TEST_PASSWORD:process.env.RESTAURANT_TEST_PASSWORD;
  if(!email||!password)return {attempted:false,reason:"credenciales-no-configuradas"};
  const emailInput=page.locator('#email,input[type="email"]').first();
  const passInput=page.locator('#password,input[type="password"]').first();
  if(!(await emailInput.count())||!(await passInput.count()))return {attempted:false,reason:"formulario-no-visible"};
  try{
    await emailInput.fill(email);await passInput.fill(password);
    const button=page.getByRole("button",{name:/Ingresar|Entrar|Iniciar sesión/i}).first();
    if(await button.count())await button.click();else await passInput.press("Enter");
    await page.waitForTimeout(1800);
    return {attempted:true,success:!(await emailInput.isVisible().catch(()=>false))};
  }catch(error){return {attempted:true,success:false,error:String(error?.message||error)}}
}

async function auditPage(browser,module,viewportName,viewport){
  const context=await browser.newContext({viewport,locale:"es-CL"});
  const page=await context.newPage();
  const errors=[],warnings=[],consoleErrors=[],requestFailures=[],httpErrors=[];
  page.on("pageerror",e=>consoleErrors.push(String(e.message||e)));
  page.on("console",m=>{if(m.type()==="error")consoleErrors.push(m.text())});
  page.on("requestfailed",req=>requestFailures.push({url:req.url(),error:req.failure()?.errorText||"falló"}));
  page.on("response",res=>{try{const u=new URL(res.url());if(u.origin===new URL(module.url).origin&&res.status()>=400)httpErrors.push({status:res.status(),url:res.url()})}catch(_){}});
  let response=null,navigationError=null;
  try{response=await page.goto(module.url,{waitUntil:"domcontentloaded",timeout:25000});await page.waitForTimeout(2200)}
  catch(error){navigationError=String(error?.message||error)}
  const login=await maybeLogin(page,module.auth);
  await page.waitForTimeout(1000);
  let metrics={};
  try{
    metrics=await page.evaluate(()=>({
      title:document.title,
      textLength:(document.body?.innerText||"").trim().length,
      bodyChildren:document.body?.children?.length||0,
      scrollWidth:document.documentElement.scrollWidth,
      innerWidth:window.innerWidth,
      scrollHeight:document.documentElement.scrollHeight,
      innerHeight:window.innerHeight,
      selectorVisible:!!document.getElementById("test-rubro-switcher")&&getComputedStyle(document.getElementById("test-rubro-switcher")).display!=="none"
    }));
  }catch(error){errors.push("No se pudo inspeccionar DOM: "+String(error?.message||error))}
  const finalUrl=page.url();let finalHost="";
  try{finalHost=new URL(finalUrl).hostname}catch(_){}
  if(navigationError)errors.push("Navegación: "+navigationError);
  if(response&&response.status()>=400)errors.push("HTTP inicial "+response.status());
  if(finalHost&&finalHost!==TEST_HOST)errors.push("Redirección fuera de Pruebas: "+finalUrl);
  if((metrics.textLength||0)<40)errors.push("Pantalla posiblemente vacía: poco texto visible");
  if((metrics.bodyChildren||0)<1)errors.push("Pantalla vacía: body sin contenido");
  if((metrics.scrollWidth||0)>(metrics.innerWidth||0)+16)warnings.push("Desbordamiento horizontal detectado");
  if(consoleErrors.length)errors.push("Errores JavaScript/consola: "+consoleErrors.length);
  const seriousHttp=httpErrors.filter(x=>x.status>=500);
  if(seriousHttp.length)errors.push("Respuestas 5xx del sitio: "+seriousHttp.length);
  if(requestFailures.filter(x=>{try{return new URL(x.url).hostname===TEST_HOST}catch(_){return false}}).length)warnings.push("Recursos del sitio fallaron al cargar");
  if(module.expectSelector&&!metrics.selectorVisible)warnings.push("Selector de rubros no visible en este menú de Pruebas");
  const screenshot=path.join(OUT,"screenshots",slugify(module.key+"-"+viewportName)+".png");
  try{await page.screenshot({path:screenshot,fullPage:true})}catch(_){}
  await context.close();
  return {module:module.key,label:module.label,viewport:viewportName,url:module.url,finalUrl,status:errors.length?"failure":warnings.length?"warning":"success",errors,warnings,consoleErrors:consoleErrors.slice(0,20),httpErrors:httpErrors.slice(0,20),requestFailures:requestFailures.slice(0,20),login,metrics,screenshot};
}

function reportPrompt(report){
  return "Eres auditor técnico de una aplicación SaaS. Analiza este informe de navegador REAL de YummyPro Pruebas. No inventes fallos. Prioriza errores visibles, rutas equivocadas, pantallas vacías, JavaScript, HTTP 5xx, responsive y selector de rubros. Responde SOLO JSON válido con esta forma: {\\\"status\\\":\\\"success|warning|failure\\\",\\\"summary\\\":\\\"...\\\",\\\"findings\\\":[{\\\"severity\\\":\\\"critical|warning|info\\\",\\\"module\\\":\\\"...\\\",\\\"title\\\":\\\"...\\\",\\\"evidence\\\":\\\"...\\\",\\\"suggestion\\\":\\\"...\\\"}]}. Informe:\\n"+JSON.stringify(report,null,2);
}

async function geminiAudit(report){
  const key=process.env.GEMINI_API_KEY;
  if(!key)return {provider:"gemini",configured:false};
  const parts=[{text:reportPrompt(report)}];
  for(const result of report.results.filter(x=>x.screenshot).slice(0,8)){
    try{
      const data=(await readFile(result.screenshot)).toString("base64");
      parts.push({text:"Captura: "+result.label+" / "+result.viewport});
      parts.push({inlineData:{mimeType:"image/png",data}});
    }catch(_){}
  }
  const endpoint="https://generativelanguage.googleapis.com/v1beta/models/"+encodeURIComponent(GEMINI_MODEL)+":generateContent";
  const res=await fetch(endpoint,{method:"POST",headers:{"Content-Type":"application/json","x-goog-api-key":key},body:JSON.stringify({contents:[{role:"user",parts}],generationConfig:{temperature:0.1,responseMimeType:"application/json"}})});
  const raw=await res.text();
  if(!res.ok)return {provider:"gemini",configured:true,error:"HTTP "+res.status,raw:raw.slice(0,1000)};
  const body=JSON.parse(raw),text=(body.candidates?.[0]?.content?.parts||[]).map(x=>x.text||"").join("");
  try{return {provider:"gemini",configured:true,model:GEMINI_MODEL,analysis:JSON.parse(text)}}catch(_){return {provider:"gemini",configured:true,model:GEMINI_MODEL,text}}
}

function compactGroqReport(report){
  return {
    created_at:report.created_at,
    status:report.status,
    counts:report.counts,
    results:(report.results||[]).map(x=>({
      module:x.module,
      label:x.label,
      viewport:x.viewport,
      status:x.status,
      finalUrl:x.finalUrl,
      errors:(x.errors||[]).slice(0,4),
      warnings:(x.warnings||[]).slice(0,4),
      consoleErrors:(x.consoleErrors||[]).slice(0,5),
      httpErrors:(x.httpErrors||[]).slice(0,5),
      metrics:x.metrics
    }))
  };
}

async function groqAudit(report){
  const key=process.env.GROQ_API_KEY;
  if(!key)return {provider:"groq",configured:false};
  const compact=compactGroqReport(report);
  const prompt="Revisa como segundo auditor este resumen técnico REAL de YummyPro Pruebas. No inventes. Devuelve SOLO JSON válido con {status:'success|warning|failure',summary:'...',findings:[{severity:'critical|warning|info',module:'...',title:'...',evidence:'...',suggestion:'...'}]}. Datos:\n"+JSON.stringify(compact);
  const res=await fetch("https://api.groq.com/openai/v1/chat/completions",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+key},body:JSON.stringify({model:GROQ_MODEL,temperature:0.1,max_completion_tokens:900,messages:[{role:"system",content:"Eres un segundo auditor de software. Devuelve solo JSON válido y no inventes evidencia."},{role:"user",content:prompt}]})});
  const raw=await res.text();
  if(!res.ok)return {provider:"groq",configured:true,error:"HTTP "+res.status,raw:raw.slice(0,1000)};
  const body=JSON.parse(raw),text=body.choices?.[0]?.message?.content||"";
  try{return {provider:"groq",configured:true,model:GROQ_MODEL,analysis:JSON.parse(text.replace(/^\\x60\\x60\\x60json\\s*|\\s*\\x60\\x60\\x60$/g,""))}}catch(_){return {provider:"groq",configured:true,model:GROQ_MODEL,text}}
}

await mkdir(path.join(OUT,"screenshots"),{recursive:true});
const browser=await chromium.launch({headless:true});
const targets=await discoverPublicTargets();
const modules=[...panelModules,...publicModules(targets)];
const viewports={desktop:{width:1440,height:900},mobile:{width:390,height:844}};
const results=[];
for(const module of modules)for(const [name,viewport] of Object.entries(viewports)){
  try{results.push(await auditPage(browser,module,name,viewport))}
  catch(error){results.push({module:module.key,label:module.label,viewport:name,url:module.url,status:"failure",errors:[String(error?.message||error)],warnings:[]})}
}
await browser.close();

const counts={success:results.filter(x=>x.status==="success").length,warning:results.filter(x=>x.status==="warning").length,failure:results.filter(x=>x.status==="failure").length};
const report={version:1,created_at:now(),targets_discovery_error:targets.__error||null,counts,status:counts.failure?"failure":counts.warning?"warning":"success",results};
const gemini=await geminiAudit(report).catch(error=>({provider:"gemini",configured:!!process.env.GEMINI_API_KEY,error:String(error?.message||error)}));
const groq=await groqAudit(report).catch(error=>({provider:"groq",configured:!!process.env.GROQ_API_KEY,error:String(error?.message||error)}));
report.ai={gemini,groq};
await writeFile(path.join(OUT,"audit.json"),JSON.stringify(report,null,2));
const lines=["# YummyPro · Auditor IA de Pruebas","","- Fecha: "+report.created_at,"- Estado navegador: **"+report.status.toUpperCase()+"**","- Éxitos: "+counts.success+" · Advertencias: "+counts.warning+" · Fallos: "+counts.failure,"- Gemini: "+(gemini.configured?(gemini.error?"error":"activo"):"sin clave"),"- Groq: "+(groq.configured?(groq.error?"error":"activo"):"sin clave"),"","## Recorridos"];
for(const x of results)lines.push("- **"+x.label+" / "+x.viewport+"** — "+x.status+" — "+([...x.errors,...x.warnings].join(" | ")||"OK"));
lines.push("","## Gemini",JSON.stringify(gemini.analysis||gemini,null,2),"","## Groq",JSON.stringify(groq.analysis||groq,null,2));
const md=lines.join("\\n");
await writeFile(path.join(OUT,"README.md"),md);
console.log(md);
const aiFailure=[gemini,groq].some(x=>x?.analysis?.status==="failure");
if(counts.failure>0||(ENFORCE_AI&&aiFailure))process.exitCode=1;
