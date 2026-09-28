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
  const local=restaurants.find(x=>Number(x.id)===Number(id))||streamingAdminBusinessById(id);
  if(!local||!isStreamingType(local.business_type))return originalOpenRestaurantPanel?originalOpenRestaurantPanel(id,section):undefined;
  if(!isSuperAdmin)return toast('Acceso exclusivo del administrador general');
  if(!originalOpenRestaurantPanel)return toast('No se pudo iniciar la vista administrativa.');

  // Streaming usa exactamente el mismo ticket temporal de un solo uso que el resto de YummyPro.
  // Nunca se comparte el access_token ni el refresh_token de la sesión principal del administrador.
  return originalOpenRestaurantPanel(id,section);
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
  list.innerHTML=view.map(r=>{const sub=subscriptionInfo(r),pct=Math.max(0,Math.min(100,(sub.days/30)*100));return '<div class="item"><div class="row between"><div><div class="row" style="gap:7px;flex-wrap:wrap"><h3 style="margin:0">'+esc(r.name)+'</h3><span class="business-type-badge">📺 Streaming</span>'+(r.is_demo?'<span class="pill">Demo</span>':'')+'</div><div class="pill subscription-'+sub.status+'">'+sub.label+'</div><div class="mut">Plan: '+esc(r.subscription_plan||'Prueba 30 días')+'</div><div class="mut">Vence: '+subscriptionExpiryDateLabel(r)+'</div><div class="sub-progress"><i style="width:'+pct+'%"></i></div></div><div class="actions"><button class="primary" onclick="streamingAdminEditSubscription('+r.id+')">Editar configuración</button><button class="ghost" onclick="streamingAdminSetSubscription('+r.id+',\'active\')">Activar</button><button class="danger" onclick="streamingAdminSetSubscription('+r.id+',\'suspended\')">Suspender</button></div></div></div>'}).join('')||"<p class='mut'>No hay suscripciones Streaming con estos filtros.</p>";
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

 function fillStreamingPaymentBusinessSelect(){
  const el=document.getElementById('subscriptionPaymentRestaurantFilter');if(!el)return;
  const selected=el.value||'all';
  el.innerHTML='<option value="all">Todos los negocios</option>'+streamingAdminBusinesses.map(r=>'<option value="'+r.id+'">'+esc(r.name)+(r.is_demo?' · Demo':'')+'</option>').join('');
  el.value=[...el.options].some(o=>o.value===selected)?selected:'all';
 }
 const originalStreamingPaymentBusinessFilter=window.syncSubscriptionPaymentBusinessFilter;
 window.syncSubscriptionPaymentBusinessFilter=function(){
  const type=document.getElementById('subscriptionPaymentBusinessTypeFilter')?.value||'all';
  if(type!=='streaming')return originalStreamingPaymentBusinessFilter?originalStreamingPaymentBusinessFilter():undefined;
  adminPaymentPage=1;
  return loadStreamingAdminBusinesses(true).then(()=>{
   fillStreamingPaymentBusinessSelect();
   renderAdminSubscriptionPaymentHistory();
  }).catch(e=>{console.error('Streaming payment filter',e);toast('No se pudieron cargar los negocios Streaming')});
 };

 const ADMIN_TEST_LINKS=[
  ['Admin','https://jorge2610g.github.io/yummy-admin-pruebas/'],
  ['Restaurante','https://jorge2610g.github.io/yummy-restaurante-pruebas/'],
  ['Retail','https://jorge2610g.github.io/yummy-retail-pruebas/'],
  ['Profesionales','https://jorge2610g.github.io/yummy-profesionales-pruebas/'],
  ['Streaming','https://jorge2610g.github.io/yummy-streaming-pruebas/'],
  ['Cliente','https://jorge2610g.github.io/yummy-cliente-pruebas/']
 ];
 const ADMIN_PRODUCTION_LINKS=[
  ['Admin','https://admin.yummypro.online/'],
  ['Restaurante','https://web.yummypro.online/'],
  ['Retail','https://retail.yummypro.online/'],
  ['Profesionales','https://pro.yummypro.online/'],
  ['Streaming','https://streaming.yummypro.online/'],
  ['Cliente','https://menu.yummypro.online/']
 ];
 function isAdminTestsEnvironment(){
  return location.hostname.toLowerCase().includes('github.io')&&location.pathname.toLowerCase().includes('/yummy-admin-pruebas');
 }
 function installAdminEnvironmentAccessStyle(){
  if(document.getElementById('admin-environment-access-style'))return;
  const style=document.createElement('style');
  style.id='admin-environment-access-style';
  style.textContent='#adminSideMenu .admin-env-trigger{width:100%;min-height:42px;padding:4px 6px;gap:9px;border:1px solid transparent;border-radius:11px;background:transparent;color:var(--mut);display:flex;align-items:center;text-align:left;cursor:pointer}#adminSideMenu .admin-env-trigger:hover,#adminSideMenu .admin-env-trigger.active{background:color-mix(in srgb,var(--a) 9%,var(--surface-2));border-color:color-mix(in srgb,var(--a) 28%,var(--line));color:var(--txt)}#adminSideMenu .admin-env-trigger .nav-icon{display:grid;place-items:center}#adminSideMenu.collapsed .admin-env-trigger{width:42px;min-width:42px;max-width:42px;height:42px;min-height:42px;padding:0;margin:0 auto;display:grid;place-items:center}#adminSideMenu.collapsed .admin-env-trigger .nav-label{display:none}#adminEnvironmentAccess .admin-env-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-top:16px}#adminEnvironmentAccess .admin-env-card{min-height:110px;padding:16px;border:1px solid var(--line);border-radius:16px;background:var(--card);display:flex;flex-direction:column;justify-content:space-between;gap:12px;text-decoration:none;color:inherit;box-shadow:0 8px 22px color-mix(in srgb,var(--shadow) 45%,transparent)}#adminEnvironmentAccess .admin-env-card:hover{border-color:color-mix(in srgb,var(--a) 45%,var(--line));transform:translateY(-1px)}#adminEnvironmentAccess .admin-env-card b{font-size:15px}#adminEnvironmentAccess .admin-env-card small{color:var(--mut);line-height:1.35}#adminEnvironmentAccess .admin-env-arrow{font-size:20px;align-self:flex-end}@media(max-width:800px){#adminSideMenu .admin-env-trigger{width:100%;min-height:44px;padding:6px 7px;gap:9px}#adminEnvironmentAccess .admin-env-grid{grid-template-columns:1fr;gap:9px}#adminEnvironmentAccess .admin-env-card{min-height:86px;padding:13px;border-radius:13px}}';
  document.head.appendChild(style);
 }
 function renderAdminEnvironmentAccessPanel(){
  const isTests=isAdminTestsEnvironment();
  const links=isTests?ADMIN_PRODUCTION_LINKS:ADMIN_TEST_LINKS;
  const section=document.getElementById('adminEnvironmentAccess');
  if(!section)return;
  const destination=isTests?'Producción':'Pruebas';
  section.innerHTML='<div class="card"><div class="section-heading"><div><span class="eyebrow">YummyPro · '+destination+'</span><h2>'+(isTests?'Volver a Producción':'Accesos de Prueba')+'</h2><p class="mut">Selecciona el módulo. La página de '+destination+' se abrirá en una pestaña nueva.</p></div></div><div class="admin-env-grid">'+links.map(([label,url])=>'<a class="admin-env-card" href="'+url+'" target="_blank" rel="noopener noreferrer"><div><b>'+label+' · '+destination+'</b><small>Abrir '+label+' en '+destination+'.</small></div><span class="admin-env-arrow">↗</span></a>').join('')+'</div></div>';
 }
 function openAdminEnvironmentAccess(){
  if(typeof isSuperAdmin!=='undefined'&&!isSuperAdmin)return toast('Acceso exclusivo del administrador general');
  const section=document.getElementById('adminEnvironmentAccess');
  const trigger=document.querySelector('[data-yummy-environment-access="trigger"]');
  if(!section||!trigger)return;
  document.querySelectorAll('#adminSideMenu .tab').forEach(x=>x.classList.remove('active'));
  document.querySelectorAll('.section').forEach(x=>x.classList.remove('active'));
  document.getElementById('adminAuthenticatedActivity')?.classList.add('hidden');
  document.getElementById('adminRestaurantScopeBar')?.style.setProperty('display','none');
  renderAdminEnvironmentAccessPanel();
  section.classList.add('active');
  trigger.classList.add('active');
  if(typeof window.closeAdminSideMenu==='function')window.closeAdminSideMenu();
 }
 window.openAdminEnvironmentAccess=openAdminEnvironmentAccess;
 function installAdminEnvironmentAccess(){
  const tabs=document.querySelector('#adminSideMenu .tabs');
  const firstSection=document.querySelector('.section');
  if(!tabs||!firstSection)return;
  installAdminEnvironmentAccessStyle();
  let section=document.getElementById('adminEnvironmentAccess');
  if(!section){
   section=document.createElement('section');
   section.id='adminEnvironmentAccess';
   section.className='section';
   firstSection.parentElement.appendChild(section);
   renderAdminEnvironmentAccessPanel();
  }
  if(!tabs.querySelector('[data-yummy-environment-access="trigger"]')){
   const trigger=document.createElement('button');
   trigger.type='button';
   trigger.className='admin-env-trigger admin-only';
   trigger.dataset.yummyEnvironmentAccess='trigger';
   trigger.title=isAdminTestsEnvironment()?'Acceso a Producción':'Acceso a Pruebas';
   trigger.innerHTML='<span class="nav-icon"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 7h11M8 12h11M8 17h11"/><circle cx="4" cy="7" r="1"/><circle cx="4" cy="12" r="1"/><circle cx="4" cy="17" r="1"/></svg></span><span class="nav-label">'+trigger.title+'</span>';
   trigger.addEventListener('click',openAdminEnvironmentAccess);
   const releaseItem=[...tabs.children].find(el=>/lanzar\s+producci/i.test(String(el.textContent||'')));
   releaseItem?.after(trigger);
   if(!trigger.isConnected)tabs.appendChild(trigger);
   tabs.querySelectorAll('.tab').forEach(tab=>tab.addEventListener('click',()=>trigger.classList.remove('active')));
  }
 }

 function refreshStreamingAdminUi(){
  installStreamingBusinessOptions();
  installAdminEnvironmentAccess();
  const copy=document.querySelector('#restaurants .card p.mut');if(copy&&copy.textContent.includes('Restaurantes, supermercados'))copy.textContent='Restaurantes, retail, profesionales y negocios Streaming administrados desde la misma plataforma.';
  refreshStreamingSummaryCard();
 }
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',refreshStreamingAdminUi);else refreshStreamingAdminUi();
 const observer=new MutationObserver(()=>{installStreamingBusinessOptions();installAdminEnvironmentAccess()});
 observer.observe(document.documentElement,{subtree:true,childList:true});
 setTimeout(refreshStreamingAdminUi,250);
})();