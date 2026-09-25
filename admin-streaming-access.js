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

 function addStreamingSummaryCard(){
  const box=document.getElementById('adminRetailSummary');if(!box||box.querySelector('[data-streaming-summary]'))return;
  const usable=r=>{const s=subscriptionInfo(r).status;return r.active!==false&&['active','trial'].includes(s)};
  const count=restaurants.filter(r=>isStreamingType(r.business_type)&&usable(r)).length;
  const card=document.createElement('article');card.className='restaurant-metric';card.dataset.streamingSummary='1';card.innerHTML='<span>Streaming activos</span><strong>'+count+'</strong><small>Negocios Streaming operativos</small>';box.insertBefore(card,box.lastElementChild||null);
 }
 const originalLoadAdminRetailSummary=window.loadAdminRetailSummary;
 window.loadAdminRetailSummary=async function(){const result=originalLoadAdminRetailSummary?await originalLoadAdminRetailSummary():undefined;addStreamingSummaryCard();return result};

 function refreshStreamingAdminUi(){installStreamingBusinessOptions();addStreamingSummaryCard();}
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',refreshStreamingAdminUi);else refreshStreamingAdminUi();
 const observer=new MutationObserver(()=>installStreamingBusinessOptions());
 observer.observe(document.documentElement,{subtree:true,childList:true});
 setTimeout(refreshStreamingAdminUi,250);
})();
