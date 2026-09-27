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
  {key:"admin",label:"Admin",url:"https://jorge2610g.github.io/yummy-admin-pruebas/",auth:"admin",sourceRepo:"jorge2610g/yummy-admin",marker:"https://jorge2610g.github.io/yummy-admin-pruebas/.staging-source-sha"},
  {key:"restaurante",label:"Restaurante",url:"https://jorge2610g.github.io/yummy-restaurante-pruebas/panel/",auth:"restaurant",sourceRepo:"jorge2610g/yummy-restaurante",marker:"https://jorge2610g.github.io/yummy-restaurante-pruebas/.staging-source-sha"},
  {key:"retail",label:"Retail",url:"https://jorge2610g.github.io/yummy-retail-pruebas/panel/",auth:"retail",sourceRepo:"jorge2610g/yummy-retail",marker:"https://jorge2610g.github.io/yummy-retail-pruebas/.staging-source-sha"},
  {key:"profesionales",label:"Profesionales",url:"https://jorge2610g.github.io/yummy-profesionales-pruebas/panel/",auth:"professional",sourceRepo:"jorge2610g/yummy-profesionales",marker:"https://jorge2610g.github.io/yummy-profesionales-pruebas/.staging-source-sha"},
  {key:"streaming",label:"Streaming",url:"https://jorge2610g.github.io/yummy-streaming-pruebas/panel/",auth:"streaming",sourceRepo:"jorge2610g/yummy-streaming",marker:"https://jorge2610g.github.io/yummy-streaming-pruebas/.staging-source-sha"}
];

const now=()=>new Date().toISOString();
const slugify=s=>String(s).toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"");

async function discoverPublicTargets(){
  try{
    const url=new URL("/rest/v1/restaurants",SUPABASE_URL);
    url.searchParams.set("select","id,slug,name,business_type,is_demo,active,white_label_enabled");
    url.searchParams.set("active","eq.true");
    url.searchParams.set("order","is_demo.desc,id.asc");
    url.searchParams.set("limit","200");
    const res=await fetch(url,{headers:{apikey:SUPABASE_KEY}});
    if(!res.ok)throw new Error("Supabase "+res.status);
    const rows=await res.json();
    const byType={};
    const list=Array.isArray(rows)?rows:[];
    for(const row of list){
      const raw=String(row.business_type||"restaurant").toLowerCase();
      const key=["supermarket","minimarket","retail"].includes(raw)?"retail":raw==="professional"?"professional":raw==="streaming"?"streaming":"restaurant";
      if(!byType[key])byType[key]=row;
      if(key==="streaming"&&row.white_label_enabled===true)byType[key]=row;
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
    list.push({
      key:"cliente-"+key,label,url:url.toString(),auth:null,expectSelector:!!row,
      sourceRepo:"jorge2610g/mipagina",
      marker:"https://jorge2610g.github.io/yummy-cliente-pruebas/.staging-source-sha"
    });
  }
  const row=targets.streaming,url=new URL(streaming);
  if(row)url.searchParams.set("business",String(row.id));
  list.push({
    key:"cliente-streaming",label:"Catálogo Streaming",url:url.toString(),auth:null,expectSelector:!!row,
    sourceRepo:"jorge2610g/yummy-streaming",
    marker:"https://jorge2610g.github.io/yummy-streaming-pruebas/.staging-source-sha",
    whiteLabelExpected:!!row?.white_label_enabled
  });
  return list;
}

async function maybeLogin(page,auth,moduleUrl){
  if(!auth)return {attempted:false};
  const credentials={
    admin:[process.env.ADMIN_TEST_EMAIL,process.env.ADMIN_TEST_PASSWORD],
    restaurant:[process.env.RESTAURANT_TEST_EMAIL,process.env.RESTAURANT_TEST_PASSWORD],
    retail:[process.env.RETAIL_TEST_EMAIL,process.env.RETAIL_TEST_PASSWORD],
    professional:[process.env.PROFESSIONAL_TEST_EMAIL,process.env.PROFESSIONAL_TEST_PASSWORD],
    streaming:[process.env.STREAMING_TEST_EMAIL,process.env.STREAMING_TEST_PASSWORD]
  };
  const [email,password]=credentials[auth]||[];
  if(!email||!password)return {attempted:false,reason:"credenciales-no-configuradas"};

  if(auth!=="admin"){
    try{
      const authUrl=new URL("/auth/v1/token",SUPABASE_URL);
      authUrl.searchParams.set("grant_type","password");
      const res=await fetch(authUrl,{
        method:"POST",
        headers:{apikey:SUPABASE_KEY,"Content-Type":"application/json"},
        body:JSON.stringify({email,password})
      });
      const raw=await res.text();
      if(!res.ok)return {attempted:true,success:false,method:"supabase-handoff",error:"Auth HTTP "+res.status+" "+raw.slice(0,240)};
      const session=JSON.parse(raw);
      if(!session?.access_token||!session?.refresh_token)return {attempted:true,success:false,method:"supabase-handoff",error:"Supabase no devolvió sesión completa"};
      const target=new URL(moduleUrl);
      target.hash=new URLSearchParams({yummy_access:session.access_token,yummy_refresh:session.refresh_token}).toString();
      await page.goto(target.toString(),{waitUntil:"domcontentloaded",timeout:25000});
      const app=page.locator("#app").first();
      let appVisible=false;
      try{await app.waitFor({state:"visible",timeout:12000});appVisible=true}catch(_){appVisible=await app.isVisible().catch(()=>false)}
      return {attempted:true,success:appVisible,method:"supabase-handoff",finalUrl:page.url(),error:appVisible?null:"El panel no quedó visible después del handoff autenticado"};
    }catch(error){return {attempted:true,success:false,method:"supabase-handoff",error:String(error?.message||error)}}
  }

  const emailInput=page.locator('#email:visible,#lEmail:visible,input[type="email"]:visible').first();
  const passInput=page.locator('#password:visible,#lPass:visible,input[type="password"]:visible').first();
  if(!(await emailInput.count())||!(await passInput.count()))return {attempted:false,reason:"formulario-no-visible"};
  try{
    await emailInput.fill(email);await passInput.fill(password);
    const button=page.getByRole("button",{name:/Ingresar|Entrar|Iniciar sesión/i}).first();
    if(await button.count())await button.click();else await passInput.press("Enter");
    await page.waitForTimeout(1800);
    return {attempted:true,success:!(await emailInput.isVisible().catch(()=>false)),method:"form"};
  }catch(error){return {attempted:true,success:false,method:"form",error:String(error?.message||error)}}
}


async function waitForExactPublishedSource(module,timeoutMs=180000){
  if(!module?.sourceRepo||!module?.marker)return {ok:true,skipped:true};
  const started=Date.now();
  let expected=null,published=null,lastError=null;
  try{
    const ref=await fetch("https://api.github.com/repos/"+module.sourceRepo+"/git/ref/heads/staging",{headers:{"Accept":"application/vnd.github+json","User-Agent":"YummyPro-Auditor"}});
    if(!ref.ok)throw new Error("GitHub "+ref.status);
    expected=(await ref.json())?.object?.sha||null;
  }catch(error){return {ok:false,sourceRepo:module.sourceRepo,error:"No se pudo leer staging: "+String(error?.message||error)}}
  while(Date.now()-started<timeoutMs){
    try{
      const res=await fetch(module.marker+"?audit="+Date.now(),{cache:"no-store"});
      published=res.ok?(await res.text()).trim():null;
      if(expected&&published===expected)return {ok:true,sourceRepo:module.sourceRepo,expected,published,waited_ms:Date.now()-started};
      lastError=res.ok?null:"Marker HTTP "+res.status;
    }catch(error){lastError=String(error?.message||error)}
    await new Promise(r=>setTimeout(r,5000));
  }
  return {ok:false,sourceRepo:module.sourceRepo,expected,published,error:lastError||"GitHub Pages no publicó el SHA exacto dentro del tiempo esperado",waited_ms:Date.now()-started};
}

async function captureAuditFrame(page,module,viewportName,label){
  const state=await page.evaluate(()=>({
    theme:document.documentElement.dataset.theme||null,
    text:(document.body?.innerText||"").replace(/\s+/g," ").trim().slice(0,5000),
    hasYummyPro:/\bYummyPro\b/i.test(document.body?.innerText||""),
    title:document.title,
    readyState:document.readyState
  })).catch(()=>({theme:null,text:"",hasYummyPro:false,title:"",readyState:"error"}));
  const file=path.join(OUT,"screenshots",slugify(module.key+"-"+viewportName+"-"+label)+".png");
  try{await page.screenshot({path:file,fullPage:false})}catch(_){}
  return {...state,label,screenshot:file};
}

async function switchThemeThroughUi(page,target){
  const current=()=>page.evaluate(()=>String(document.documentElement.dataset.theme||"")).catch(()=>"");
  if((await current())===target)return {supported:true,changed:false,theme:target};
  const button=page.locator('#themeBtn:visible,[data-theme-toggle]:visible,button[aria-label*="modo" i]:visible,button[title*="modo" i]:visible').first();
  if(!(await button.count()))return {supported:false,changed:false,theme:await current()};
  for(let attempt=0;attempt<3;attempt++){
    try{await button.click({timeout:3000});await page.waitForTimeout(180)}catch(_){}
    if((await current())===target)return {supported:true,changed:true,theme:target};
  }
  return {supported:true,changed:false,theme:await current(),error:"El control de tema no llegó a "+target};
}

async function inspectVisualLayout(page,theme){
  return page.evaluate(({theme})=>{
    const visible=el=>{
      const s=getComputedStyle(el),r=el.getBoundingClientRect();
      return s.display!=="none"&&s.visibility!=="hidden"&&Number(s.opacity||1)>0.02&&r.width>0&&r.height>0;
    };
    const rgb=value=>{
      const m=String(value||"").match(/rgba?\(([\d.]+)[ ,]+([\d.]+)[ ,]+([\d.]+)/i);
      return m?[Number(m[1]),Number(m[2]),Number(m[3])]:null;
    };
    const lum=value=>{
      const v=rgb(value);if(!v)return null;
      return .2126*v[0]+.7152*v[1]+.0722*v[2];
    };
    const selector="button,a[href],input,select,textarea,[role=button]";
    const interactive=[...document.querySelectorAll(selector)].filter(visible);
    const clipped=[],covered=[],tiny=[];
    for(const el of interactive){
      const r=el.getBoundingClientRect();
      if(r.bottom<0||r.top>innerHeight||r.right<0||r.left>innerWidth)continue;
      const name=(el.getAttribute("aria-label")||el.getAttribute("title")||el.innerText||el.value||el.tagName).replace(/\s+/g," ").trim().slice(0,90);
      if(r.left<-2||r.right>innerWidth+2)clipped.push({name,left:Math.round(r.left),right:Math.round(r.right),viewport:innerWidth});
      if((el.scrollWidth>el.clientWidth+5||el.scrollHeight>el.clientHeight+5)&&r.width>30&&r.height>20)clipped.push({name,overflow:true,client:[el.clientWidth,el.clientHeight],scroll:[el.scrollWidth,el.scrollHeight]});
      if(r.width<24||r.height<24)tiny.push({name,size:[Math.round(r.width),Math.round(r.height)]});
      const x=Math.min(innerWidth-1,Math.max(0,r.left+r.width/2)),y=Math.min(innerHeight-1,Math.max(0,r.top+r.height/2));
      const top=document.elementFromPoint(x,y);
      if(top&&top!==el&&!el.contains(top)&&!top.contains(el)){
        const ts=getComputedStyle(top);
        if(ts.pointerEvents!=="none")covered.push({name,by:(top.getAttribute("aria-label")||top.getAttribute("title")||top.className||top.tagName).toString().slice(0,100)});
      }
    }
    const surfaces=[...document.querySelectorAll('.card,.item,[class*="card"],[class*="panel"],[class*="toolbar"],[class*="streaming-"]')]
      .filter(visible).map(el=>{
        const r=el.getBoundingClientRect(),s=getComputedStyle(el),l=lum(s.backgroundColor);
        return {className:String(el.className||"").slice(0,120),area:Math.round(r.width*r.height),background:s.backgroundColor,luminance:l};
      }).filter(x=>x.area>5000&&x.luminance!=null);
    const themeMismatch=surfaces.filter(x=>theme==="light"?x.luminance<75:x.luminance>225).slice(0,12);
    return {
      theme,
      horizontalOverflow:document.documentElement.scrollWidth>innerWidth+16,
      scrollWidth:document.documentElement.scrollWidth,
      innerWidth,
      clipped:clipped.slice(0,12),
      covered:covered.slice(0,12),
      tiny:tiny.slice(0,12),
      themeMismatch,
      surfaceCount:surfaces.length
    };
  },{theme}).catch(error=>({theme,error:String(error?.message||error),clipped:[],covered:[],tiny:[],themeMismatch:[]}));
}

async function auditNavigation(page,module,viewportName){
  if(viewportName!=="desktop"||!module.auth)return {tabs:[],streamingRules:[]};
  const tabs=page.locator('.tab[data-tab]:visible');
  const count=Math.min(await tabs.count(),18);
  const results=[],streamingRules=[];
  for(let i=0;i<count;i++){
    const tab=tabs.nth(i);
    const label=((await tab.innerText().catch(()=>""))||await tab.getAttribute("title")||"tab").replace(/\s+/g," ").trim();
    const dataTab=await tab.getAttribute("data-tab");
    try{await tab.click({timeout:2500});await page.waitForTimeout(220)}catch(error){
      results.push({label,dataTab,status:"failure",error:String(error?.message||error)});continue;
    }
    const active=await page.evaluate(tabId=>{
      const section=tabId?document.getElementById(tabId):null;
      const body=(section?.innerText||"").replace(/\s+/g," ").trim();
      const style=section?getComputedStyle(section):null;
      return {textLength:body.length,text:body.slice(0,4500),visible:!!section&&style?.display!=="none"&&style?.visibility!=="hidden"};
    },dataTab).catch(()=>({textLength:0,text:"",visible:false}));
    const visual=await inspectVisualLayout(page,await page.evaluate(()=>document.documentElement.dataset.theme||"").catch(()=>""));
    results.push({label,dataTab,status:active.visible&&active.textLength>20?"success":"warning",active,visual});

    if(module.key==="streaming"&&/config|ajuste|setting/i.test(label+" "+dataTab)){
      const bad=[];
      for(const term of ["Delivery","Marca del restaurante","Ubicación del restaurante","Rangos de delivery","Meseros","Cocina","Comanda"]){
        if(new RegExp(term,"i").test(active.text))bad.push(term);
      }
      const restaurantEmoji=/🍔|🍽|🍴|👨‍🍳|🥘/.test(active.text);
      if(restaurantEmoji)bad.push("iconografía de restaurante");
      if(bad.length)streamingRules.push({type:"wrong-vertical-content",tab:label,evidence:bad});
      const shot=path.join(OUT,"screenshots",slugify(module.key+"-"+viewportName+"-"+label)+".png");
      try{await page.screenshot({path:shot,fullPage:true})}catch(_){}
    }
  }
  return {tabs:results,streamingRules};
}

async function auditPage(browser,module,viewportName,viewport){
  const context=await browser.newContext({viewport,locale:"es-CL"});
  const page=await context.newPage();
  const errors=[],warnings=[],consoleErrors=[],requestFailures=[],httpErrors=[],frames=[];
  page.on("pageerror",e=>consoleErrors.push(String(e.message||e)));
  page.on("console",m=>{if(m.type()==="error")consoleErrors.push(m.text())});
  page.on("requestfailed",req=>requestFailures.push({url:req.url(),error:req.failure()?.errorText||"falló"}));
  page.on("response",res=>{try{const u=new URL(res.url());if(res.status()>=400)httpErrors.push({status:res.status(),url:u.origin+u.pathname})}catch(_){}});
  let response=null,navigationError=null;

  try{
    response=await page.goto(module.url,{waitUntil:"domcontentloaded",timeout:25000});
    frames.push(await captureAuditFrame(page,module,viewportName,"t0"));
    await page.waitForTimeout(180);frames.push(await captureAuditFrame(page,module,viewportName,"t180"));
    await page.waitForTimeout(520);frames.push(await captureAuditFrame(page,module,viewportName,"t700"));
    await page.waitForTimeout(900);frames.push(await captureAuditFrame(page,module,viewportName,"settled"));
  }catch(error){navigationError=String(error?.message||error)}

  const login=await maybeLogin(page,module.auth,module.url);
  await page.waitForTimeout(900);

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
      selectorVisible:!!document.getElementById("test-rubro-switcher")&&getComputedStyle(document.getElementById("test-rubro-switcher")).display!=="none",
      theme:document.documentElement.dataset.theme||null,
      visibleText:(document.body?.innerText||"").replace(/\s+/g," ").trim().slice(0,8000)
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

  const missingAuth=!!module.auth&&!login.attempted&&login.reason==="credenciales-no-configuradas";
  const missingLoginForm=!!module.auth&&!login.attempted&&login.reason==="formulario-no-visible";
  const failedLogin=!!module.auth&&login.attempted&&login.success===false;
  const effectiveConsoleErrors=consoleErrors.filter(message=>!(missingAuth&&/\b401\b|unauthorized/i.test(message)));
  if(missingAuth)warnings.push("Área autenticada no recorrida: faltan credenciales de prueba en GitHub Secrets");
  if(missingLoginForm)errors.push("Formulario de inicio de sesión no disponible");
  if(failedLogin)errors.push("Inicio de sesión automático falló"+(login.error?": "+String(login.error).split("\n")[0]:""));
  if(effectiveConsoleErrors.length)errors.push("Errores JavaScript/consola: "+effectiveConsoleErrors.length);
  const seriousHttp=httpErrors.filter(x=>x.status>=500);
  if(seriousHttp.length)errors.push("Respuestas 5xx: "+seriousHttp.length+" ("+seriousHttp.slice(0,3).map(x=>x.url).join(", ")+")");
  const unauthorized=httpErrors.filter(x=>x.status===401);
  if(unauthorized.length&&!missingAuth)errors.push("Respuestas 401 inesperadas: "+unauthorized.length+" ("+unauthorized.slice(0,3).map(x=>x.url).join(", ")+")");
  if(requestFailures.filter(x=>{try{return new URL(x.url).hostname===TEST_HOST}catch(_){return false}}).length)warnings.push("Recursos del sitio fallaron al cargar");
  if(module.expectSelector&&!metrics.selectorVisible)warnings.push("Selector de rubros no visible en este menú de Pruebas");

  // Auditoría de parpadeo de marca: si al final está white-label, YummyPro no debe aparecer ni un frame antes.
  if(module.key==="cliente-streaming"&&module.whiteLabelExpected){
    const finalHasBrand=/\bYummyPro\b/i.test(metrics.visibleText||"");
    const flash=frames.slice(0,-1).some(x=>x.hasYummyPro)&&!finalHasBrand;
    if(flash)errors.push("Destello de marca detectado: YummyPro aparece durante la carga antes de aplicar Marca Blanca");
    if(finalHasBrand)errors.push("Marca Blanca esperada, pero YummyPro sigue visible al terminar la carga");
  }

  // Auditoría real de ambos temas usando el control visible.
  const themeResults={};
  for(const theme of ["light","dark"]){
    const switched=await switchThemeThroughUi(page,theme);
    if(switched.supported){
      await page.waitForTimeout(180);
      const visual=await inspectVisualLayout(page,theme);
      const shot=path.join(OUT,"screenshots",slugify(module.key+"-"+viewportName+"-"+theme)+".png");
      try{await page.screenshot({path:shot,fullPage:true})}catch(_){}
      themeResults[theme]={switched,visual,screenshot:shot};
      if(visual.clipped?.length)errors.push("Controles cortados/desbordados en modo "+theme+": "+visual.clipped.length);
      if(visual.covered?.length)errors.push("Controles tapados por otros elementos en modo "+theme+": "+visual.covered.length);
      if(visual.themeMismatch?.length>=3){
        const msg="Superficies con color incompatible con modo "+theme+": "+visual.themeMismatch.length;
        if(module.key==="streaming"||module.key==="cliente-streaming")errors.push(msg);else warnings.push(msg);
      }
    }else if(module.key==="streaming"||module.key==="cliente-streaming"){
      errors.push("Streaming no ofrece un control visible para cambiar modo claro/oscuro");
    }
  }

  const navigation=await auditNavigation(page,module,viewportName);
  for(const rule of navigation.streamingRules||[]){
    errors.push("Contenido de otro nicho visible en Streaming ("+rule.tab+"): "+rule.evidence.join(", "));
  }

  const screenshot=path.join(OUT,"screenshots",slugify(module.key+"-"+viewportName)+".png");
  try{await page.screenshot({path:screenshot,fullPage:true})}catch(_){}
  await context.close();
  return {
    module:module.key,label:module.label,viewport:viewportName,url:module.url,finalUrl,
    status:errors.length?"failure":warnings.length?"warning":"success",
    errors,warnings,consoleErrors:consoleErrors.slice(0,20),httpErrors:httpErrors.slice(0,30),
    requestFailures:requestFailures.slice(0,20),login,metrics,screenshot,
    frames,themeResults,navigation
  };
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
