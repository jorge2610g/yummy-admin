/* YummyPro Admin · integración Streaming v1.0.0 */
(function(){
 const STREAMING_ORIGIN='https://streaming.yummypro.online';
 const STREAMING_MODULES=[
  ['dashboard','Dashboard'],
  ['streaming_subscriptions','Suscripciones'],
  ['streaming_customers','Clientes'],
  ['streaming_accounts','Cuentas / Cupos'],
  ['streaming_platforms','Plataformas'],
  ['streaming_renewals','Renovaciones'],
  ['qr','Código QR'],
  ['settings','Configuración']
 ];
 const STREAMING_DEFAULTS=['dashboard','streaming_subscriptions','streaming_customers','streaming_accounts','streaming_platforms','streaming_renewals','qr','settings'];

 function isStreamingType(value){return String(value||'').toLowerCase()==='streaming'}
 function addStreamingOption(select){
  if(!select||select.querySelector('option[value="streaming"]'))return;
  const hasBusinessTypes=select.querySelector('option[value="professional"]')&&(select.querySelector('option[value="restaurant"]')||select.querySelector('option[value="supermarket"]'));
  if(!hasBusinessTypes)return;
  const option=document.createElement('option');option.value='streaming';option.textContent='Streaming';
  const all=select.querySelector('option[value="all"]');all?select.insertBefore(option,all):select.appendChild(option);
 }
 function installStreamingBusinessOptions(){document.querySelectorAll('select').forEach(addStreamingOption)}

 const originalBusinessTypeLabel=window.businessTypeLabel;
 window.businessTypeLabel=function(type){return isStreamingType(type)?'Streaming':(originalBusinessTypeLabel?originalBusinessTypeLabel(type):String(type||'Restaurante'))};
 const originalAdminBusinessLabel=window.adminBusinessLabel;
 window.adminBusinessLabel=function(type){return isStreamingType(type)?'Streaming':(originalAdminBusinessLabel?originalAdminBusinessLabel(type):window.businessTypeLabel(type))};
 const originalAdminBusinessIcon=window.adminBusinessIcon;
 window.adminBusinessIcon=function(type){return isStreamingType(type)?'📺':(originalAdminBusinessIcon?originalAdminBusinessIcon(type):'🏪')};

 try{
  if(typeof ADMIN_PLAN_MODULES!=='undefined')ADMIN_PLAN_MODULES.streaming=STREAMING_MODULES;
  if(typeof ADMIN_PLAN_DEFAULTS!=='undefined')ADMIN_PLAN_DEFAULTS.streaming=STREAMING_DEFAULTS;
 }catch(e){console.error('Streaming plan modules',e)}

 async function openStreamingBusinessProfile(r){
  currentRestaurant=r.id;
  if(window.profileRestaurantName)profileRestaurantName.textContent=r.name;
  if(window.restaurantProfileContent)restaurantProfileContent.innerHTML='<p class="mut">Cargando uso de Streaming…</p>';
  openAdminFormModal('restaurantProfileModal');
  const safe=async q=>{try{const res=await q;return res?.data||[]}catch(_){return []}};
  const [subs,customers,accounts,platforms,renewals]=await Promise.all([
   safe(sb.from('streaming_subscriptions').select('id,status,payment_status,delivery_status,expires_at,created_at').eq('restaurant_id',r.id).order('expires_at',{ascending:true}).limit(5000)),
   safe(sb.from('streaming_customers').select('id').eq('restaurant_id',r.id).limit(5000)),
   safe(sb.from('streaming_accounts').select('id,active,max_slots').eq('restaurant_id',r.id).limit(5000)),
   safe(sb.from('streaming_platforms').select('id,active').eq('restaurant_id',r.id).limit(5000)),
   safe(sb.from('streaming_renewals').select('id,created_at').eq('restaurant_id',r.id).order('created_at',{ascending:false}).limit(5000))
  ]);
  const now=Date.now(),weekAgo=now-7*86400000;
  const derived=s=>s.status==='cancelled'?'cancelled':s.status==='paused'?'paused':new Date(s.expires_at).getTime()<=now?'expired':'active';
  const days=s=>Math.ceil((new Date(s.expires_at).getTime()-now)/86400000);
  const active=subs.filter(s=>derived(s)==='active');
  const urgent=active.filter(s=>{const d=days(s);return Number.isFinite(d)&&d>=0&&d<=3});
  const expired=subs.filter(s=>derived(s)==='expired');
  const paymentPending=subs.filter(s=>String(s.payment_status||'pending')==='pending'&&derived(s)!=='cancelled');
  const deliveryPending=subs.filter(s=>String(s.delivery_status||'pending')==='pending'&&!['cancelled','paused'].includes(derived(s)));
  const renewalsWeek=renewals.filter(x=>new Date(x.created_at).getTime()>=weekAgo).length;
  const sub=subscriptionInfo(r);
  restaurantProfileContent.innerHTML='<div class="profile-360-grid">'
   +'<div class="item"><span class="mut">Tipo</span><h3>Streaming</h3></div>'
   +'<div class="item"><span class="mut">Suscripción YummyPro</span><h3>'+esc(sub.label)+'</h3></div>'
   +'<div class="item"><span class="mut">Clientes registrados</span><h3>'+customers.length+'</h3></div>'
   +'<div class="item"><span class="mut">Suscripciones activas</span><h3>'+active.length+'</h3></div>'
   +'<div class="item"><span class="mut">Vencen en 3 días</span><h3>'+urgent.length+'</h3></div>'
   +'<div class="item"><span class="mut">Vencidas</span><h3>'+expired.length+'</h3></div>'
   +'<div class="item"><span class="mut">Cobros pendientes</span><h3>'+paymentPending.length+'</h3></div>'
   +'<div class="item"><span class="mut">Entregas pendientes</span><h3>'+deliveryPending.length+'</h3></div>'
   +'<div class="item"><span class="mut">Cuentas activas</span><h3>'+accounts.filter(x=>x.active!==false).length+'</h3></div>'
   +'<div class="item"><span class="mut">Plataformas activas</span><h3>'+platforms.filter(x=>x.active!==false).length+'</h3></div>'
   +'<div class="item"><span class="mut">Renovaciones · 7 días</span><h3>'+renewalsWeek+'</h3></div>'
   +'</div><div class="actions" style="margin-top:16px">'
   +'<button class="ghost" onclick="closeAdminFormModal(\'restaurantProfileModal\');editRestaurant('+r.id+')">Editar perfil</button>'
   +'<button class="primary" onclick="openRestaurantPanel('+r.id+',\'streaming_subscriptions\')">Suscripciones</button>'
   +'<button class="ghost" onclick="openRestaurantPanel('+r.id+',\'streaming_customers\')">Clientes</button>'
   +'<button class="ghost" onclick="openRestaurantPanel('+r.id+',\'streaming_accounts\')">Cuentas / Cupos</button>'
   +'<button class="ghost" onclick="openRestaurantPanel('+r.id+',\'dashboard\')">Abrir panel</button>'
   +'</div>';
 }
 window.openStreamingBusinessProfile=openStreamingBusinessProfile;

 const originalOpenRestaurantProfile=window.openRestaurantProfile;
 window.openRestaurantProfile=async function(id){
  const r=restaurants.find(x=>Number(x.id)===Number(id));
  if(r&&isStreamingType(r.business_type))return openStreamingBusinessProfile(r);
  return originalOpenRestaurantProfile?originalOpenRestaurantProfile(id):undefined;
 };

 const originalOpenRestaurantPanel=window.openRestaurantPanel;
 window.openRestaurantPanel=async function(id,section='dashboard'){
  const r=restaurants.find(x=>Number(x.id)===Number(id));
  if(!r||!isStreamingType(r.business_type))return originalOpenRestaurantPanel?originalOpenRestaurantPanel(id,section):undefined;
  if(!isSuperAdmin)return toast('Acceso exclusivo del administrador general');
  const w=window.open('about:blank','_blank');
  if(!w)return toast('El navegador bloqueó la nueva pestaña. Habilita ventanas emergentes para abrir el panel.');
  let session=null;
  try{session=(await sb.auth.getSession()).data?.session||null}catch(_){session=null}
  if(!session?.access_token||!session?.refresh_token){try{w.close()}catch(_){}return toast('Tu sesión de administrador venció. Vuelve a iniciar sesión.')}
  const baseTarget=STREAMING_ORIGIN+'/panel?admin_preview='+encodeURIComponent(id)+'&tab='+encodeURIComponent(section);
  const handoff='#admin_access='+encodeURIComponent(session.access_token)+'&admin_refresh='+encodeURIComponent(session.refresh_token);
  const target=baseTarget+handoff;
  try{w.location.replace(target)}catch(_){w.location.href=target}
  const payload={type:'YUMMY_ADMIN_PREVIEW',restaurant_id:Number(id),tab:section,access_token:session.access_token,refresh_token:session.refresh_token};
  let attempts=0,acknowledged=false;
  const send=()=>{if(acknowledged||w.closed)return;attempts++;try{w.postMessage(payload,STREAMING_ORIGIN)}catch(_){}if(attempts<40)setTimeout(send,400)};
  const onReady=e=>{if(e.origin!==STREAMING_ORIGIN||e.source!==w||e.data?.type!=='YUMMY_ADMIN_PREVIEW_READY')return;acknowledged=true;try{w.postMessage(payload,STREAMING_ORIGIN)}catch(_){};setTimeout(()=>window.removeEventListener('message',onReady),1500)};
  window.addEventListener('message',onReady);setTimeout(send,250);
 };



 let streamingAdminBusinesses=[];
 let streamingAdminBusinessesLoaded=false;
 let streamingAdminBusinessesPromise=null;

 async function loadStreamingAdminBusinesses(force=false){
  if(streamingAdminBusinessesLoaded&&!force)return streamingAdminBusinesses;
  if(streamingAdminBusinessesPromise&&!force)return streamingAdminBusinessesPromise;
  streamingAdminBusinessesPromise=(async()=>{
   const {data,error}=await sb.from('restaurants').select('*').eq('business_type','streaming').order('created_at',{ascending:false}).limit(5000);
   if(error)throw error;
   streamingAdminBusinesses=data||[];
   streamingAdminBusinessesLoaded=true;
   return streamingAdminBusinesses;
  })();
  try{return await streamingAdminBusinessesPromise}finally{streamingAdminBusinessesPromise=null}
 }
 function streamingAdminBusinessById(id){return streamingAdminBusinesses.find(x=>Number(x.id)===Number(id))||restaurants.find(x=>Number(x.id)===Number(id))}
 function ensureStreamingBusinessInRuntime(id){
  const r=streamingAdminBusinessById(id);if(!r)return null;
  if(!restaurants.some(x=>Number(x.id)===Number(r.id)))restaurants.push(r);
  return r;
 }
 function fillStreamingSubscriptionBusinessSelect(){
  const el=document.getElementById('subscriptionRestaurantFilter');if(!el)return;
  const selected=el.value||'all';
  el.innerHTML='<option value="all">Todos los negocios</option>'+streamingAdminBusinesses.map(r=>'<option value="'+r.id+'">'+esc(r.name)+(r.is_demo?' · Demo':'')+'</option>').join('');
  el.value=[...el.options].some(o=>o.value===selected)?selected:'all';
 }
 function renderStreamingAdminSubscriptions(){
  const list=document.getElementById('subscriptionList');if(!list)return;
  ensurePager('subscriptionList','subscriptionPagination');
  const rid=document.getElementById('subscriptionRestaurantFilter')?.value||'all';
  const status=document.getElementById('subscriptionStatusFilter')?.value||'all';
  const term=(document.getElementById('subscriptionSearch')?.value||'').trim().toLowerCase();
  let rows=streamingAdminBusinesses.filter(r=>{const sub=subscriptionInfo(r);return(rid==='all'||String(r.id)===rid)&&(status==='all'||sub.status===status)&&(!term||String(r.name||'').toLowerCase().includes(term))});
  const pageSize=Number(window.ADMIN_PAGE_SIZE||20),pages=Math.max(1,Math.ceil(rows.length/pageSize));
  adminSubscriptionPage=Math.min(Math.max(1,Number(adminSubscriptionPage||1)),pages);
  const view=rows.slice((adminSubscriptionPage-1)*pageSize,adminSubscriptionPage*pageSize);
  list.innerHTML=view.map(r=>{const sub=subscriptionInfo(r),pct=Math.max(0,Math.min(100,(sub.days/30)*100));return '<div class="item"><div class="row between"><div><div class="row" style="gap:7px;flex-wrap:wrap"><h3 style="margin:0">'+esc(r.name)+'</h3><span class="business-type-badge">📺 Streaming</span>'+(r.is_demo?'<span class="pill">Demo</span>':'')+'</div><div class="pill subscription-'+sub.status+'">'+sub.label+'</div><div class="mut">Plan: '+esc(r.subscription_plan||'Prueba 30 días')+' · Precio: '+money(r.subscription_price,r.currency_code,r.locale)+'</div><div class="mut">Vence: '+subscriptionExpiryDateLabel(r)+'</div><div class="sub-progress"><i style="width:'+pct+'%"></i></div></div><div class="actions"><button class="primary" onclick="streamingAdminEditSubscription('+r.id+')">Editar configuración</button><button class="ghost" onclick="streamingAdminSetSubscription('+r.id+',\'active\')">Activar</button><button class="danger" onclick="streamingAdminSetSubscription('+r.id+',\'suspended\')">Suspender</button></div></div></div>'}).join('')||"<p class='mut'>No hay suscripciones Streaming con estos filtros.</p>";
  adminPager('subscriptionPagination',adminSubscriptionPage,rows.length,pageSize,'setAdminSubscriptionPage');
 }
 window.streamingAdminEditSubscription=async function(id){
  const r=ensureStreamingBusinessInRuntime(id);if(!r)return toast('No se encontró el negocio Streaming');
  return editSubscription(id);
 };
 window.streamingAdminSetSubscription=async function(id,status){
  const r=ensureStreamingBusinessInRuntime(id);if(!r)return toast('No se encontró el negocio Streaming');
  return setSubscription(id,status);
 };

 const originalSyncSubscriptionBusinessFilter=window.syncSubscriptionBusinessFilter;
 window.syncSubscriptionBusinessFilter=function(){
  const type=document.getElementById('subscriptionBusinessTypeFilter')?.value||'all';
  if(type!=='streaming')return originalSyncSubscriptionBusinessFilter?originalSyncSubscriptionBusinessFilter():undefined;
  adminSubscriptionPage=1;
  const list=document.getElementById('subscriptionList');if(list)list.innerHTML='<div class="item"><b>Cargando suscripciones Streaming…</b></div>';
  return loadStreamingAdminBusinesses(true).then(()=>{fillStreamingSubscriptionBusinessSelect();renderStreamingAdminSubscriptions()}).catch(e=>{console.error(e);if(list)list.innerHTML="<p class='mut'>No se pudieron cargar las suscripciones Streaming.</p>"});
 };
 const originalRenderSubscriptions=window.renderSubscriptions;
 window.renderSubscriptions=function(){
  const type=document.getElementById('subscriptionBusinessTypeFilter')?.value||'all';
  if(type!=='streaming')return originalRenderSubscriptions?originalRenderSubscriptions():undefined;
  if(!streamingAdminBusinessesLoaded){
   const list=document.getElementById('subscriptionList');if(list)list.innerHTML='<div class="item"><b>Cargando suscripciones Streaming…</b></div>';
   loadStreamingAdminBusinesses().then(()=>{fillStreamingSubscriptionBusinessSelect();renderStreamingAdminSubscriptions()}).catch(e=>console.error(e));
   return;
  }
  return renderStreamingAdminSubscriptions();
 };

 const originalPaymentHistoryBaseRows=window.paymentHistoryBaseRows;
 window.paymentHistoryBaseRows=function(type,rid,provider){
  if(type!=='streaming')return originalPaymentHistoryBaseRows?originalPaymentHistoryBaseRows(type,rid,provider):[];
  return (subscriptionPayments||[]).filter(p=>{const r=streamingAdminBusinessById(p.restaurant_id);return !!r&&(rid==='all'||String(p.restaurant_id)===rid)&&(provider==='all'||providerGroup(p.provider)===provider)});
 };

 async function refreshStreamingSummaryCard(){
  const box=document.getElementById('adminRetailSummary');if(!box)return;
  let count=0;
  try{const result=await sb.from('restaurants').select('id',{count:'exact',head:true}).eq('business_type','streaming');count=Number(result.count||0)}catch(e){console.error('Streaming admin count',e)}
  let card=box.querySelector('[data-streaming-summary]');
  if(!card){card=document.createElement('article');card.className='restaurant-metric';card.dataset.streamingSummary='1';box.insertBefore(card,box.lastElementChild||null)}
  card.innerHTML='<span>Negocios Streaming</span><strong>'+count+'</strong><small>Registrados en YummyPro Streaming</small>';
 }
 const originalRenderAdminBusinessSummaryServer=window.renderAdminBusinessSummaryServer;
 window.renderAdminBusinessSummaryServer=function(){const result=originalRenderAdminBusinessSummaryServer?originalRenderAdminBusinessSummaryServer():undefined;refreshStreamingSummaryCard();return result};
 const originalLoadAdminRetailSummary=window.loadAdminRetailSummary;
 window.loadAdminRetailSummary=async function(){const result=originalLoadAdminRetailSummary?await originalLoadAdminRetailSummary():undefined;await refreshStreamingSummaryCard();return result};

 function refreshStreamingAdminUi(){
  installStreamingBusinessOptions();
  const copy=document.querySelector('#restaurants .card p.mut');if(copy&&copy.textContent.includes('Restaurantes, supermercados'))copy.textContent='Restaurantes, retail, profesionales y negocios Streaming administrados desde la misma plataforma.';
  refreshStreamingSummaryCard();
 }
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',refreshStreamingAdminUi);else refreshStreamingAdminUi();
 const observer=new MutationObserver(()=>installStreamingBusinessOptions());
 observer.observe(document.documentElement,{subtree:true,childList:true});
 setTimeout(refreshStreamingAdminUi,250);
})();
