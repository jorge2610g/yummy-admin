import {readFileSync} from 'node:fs';
for(const file of ['index.html','panel.html','panel/index.html']){
  const html=readFileSync(file,'utf8');
  if(!/<!doctype html>/i.test(html)||!/<\/html>/i.test(html))throw new Error(`${file}: HTML incompleto`);
  if(file==='index.html'){
    if(!html.includes('data-theme'))throw new Error(`${file}: falta data-theme`);
    if(!html.includes('SB_URL'))throw new Error(`${file}: falta SB_URL`);
    for(const marker of ['adminSubscriptionPaymentHistory','loadAdminSubscriptionPaymentHistory','subscription_payments','data-tab="customers"','loadAdminOverview','openRestaurantProfile','restaurant_order_status_events','metricRestaurants','metricActiveSubscriptions','metricOrders','metricTotalSales','value="promotions"','value="reviews"']){
      if(!html.includes(marker))throw new Error(`${file}: falta módulo o indicador ${marker}`);
    }
    for(const removed of ['data-tab="kitchenAdmin"','data-tab="financeAdmin"','data-tab="inventoryAdmin"','data-tab="promotionsAdmin"','data-tab="reviewsAdmin"']){
      if(html.includes(removed))throw new Error(`${file}: todavía aparece opción eliminada ${removed}`);
    }
  }
}

const admin=readFileSync('index.html','utf8');for(const marker of ['currencyDigits','minimumFractionDigits:shown','maximumFractionDigits:shown','restaurantMoney(value,rid)'])if(!admin.includes(marker))throw new Error('index.html: falta formato monetario adaptable '+marker);

const flowMarkers=['flowCredentialsCard','subscriptionFlowApiKey','subscriptionFlowSecretKey','subscriptionFlowEnvironment','loadSubscriptionFlowSettings','saveSubscriptionFlowSettings','subscription-flow-settings'];for(const marker of flowMarkers)if(!admin.includes(marker))throw new Error('index.html: falta configuración Flow '+marker);

for(const marker of ['planAnnualEnabled','planAnnualAmount','planAnnualBonusMonths','planAnnualDays','updateAnnualPlanPreview','annual_enabled','annual_bonus_months'])if(!admin.includes(marker))throw new Error('index.html: falta configuración anual '+marker);

for(const marker of ['manifest.webmanifest','adminPwaInstall','installAdminPwa','adminPwaNetwork','adminPwaUpdate','admin-pwa-script-v2320','Versión v2.3.48'])if(!admin.includes(marker))throw new Error('index.html: falta PWA Admin '+marker);
for(const marker of ['settingsBusinessGroupFilter','changeSettingsBusinessGroup','settingsRestaurantSelect','changeSettingsRestaurant','settingsBusinessBadge','demoApiInheritanceCard','demoApiInheritanceToggle','toggleDemoApiInheritance','set_demo_business_api_inheritance','use_demo_api_defaults','is_demo','API global de demos','Locales reales','Locales demo'])if(!admin.includes(marker))throw new Error('index.html: falta configuración de APIs para demos '+marker);
for(const marker of ['data-tab="restaurants" title="Negocios"','<span class="nav-label">Negocios</span>','Ver información del negocio'])if(!admin.includes(marker))throw new Error('index.html: falta nomenclatura general de negocios '+marker);

if(!admin.includes('/manifest.webmanifest?v=2320'))throw new Error('index.html: falta manifest PWA admin versionado');

for(const marker of ['adminObservabilityPanel','loadAdminObservability','admin_observability_summary','admin_plan_recommendations','obsSystemErrors','obsUserErrors','obsRecommendations','obsRecentReports'])if(!admin.includes(marker))throw new Error('index.html: falta observabilidad admin '+marker);

for(const marker of ['rbusinessType','business_type','adminRetailSummary','loadAdminRetailSummary','openRetailBusinessProfile','retail_products','retail_sales','retail_purchases','Restaurantes activos','Negocios activos'])if(!admin.includes(marker))throw new Error('index.html: falta infraestructura retail admin '+marker);

for(const marker of ['retail_online_orders','Pedidos online activos','Ver tienda online','retail_orders','Operaciones totales','Últimos 7 días'])if(!admin.includes(marker))throw new Error('index.html: falta monitoreo de uso retail admin '+marker);

for(const removed of ['Ventas totales','Ventas de hoy','Ticket promedio','Ingresos por servicios','Venta neta total','Venta online','Total compras','spentByCurrency'])if(admin.includes(removed))throw new Error('index.html: todavía expone métrica monetaria del negocio '+removed);

for(const marker of ['Actividad total','Actividad este mes','Negocios activos · 7 días','Reservas creadas · 7 días'])if(!admin.includes(marker))throw new Error('index.html: falta analítica de uso por cantidades '+marker);

for(const marker of ['admin-mobile-information-v2325','mobile-section-switcher','restaurantBusinessTypeFilter','subscriptionBusinessTypeFilter','subscriptionPaymentBusinessTypeFilter','staffBusinessTypeFilter','customerBusinessTypeFilter','planBusinessType','business_type','retail_orders','retail_pos','retail_products','retail_suppliers','retail_purchases','Métodos de cobro'])if(!admin.includes(marker))throw new Error('index.html: falta navegación/filtros móviles '+marker);

if(!admin.includes('/admin-streaming-access.js?v=1001'))throw new Error('index.html: falta integración Streaming del admin');
const streamingAdmin=readFileSync('admin-streaming-access.js','utf8');
for(const marker of ['integración Streaming v1.0.0','https://streaming.yummypro.online','Negocios Streaming','openStreamingBusinessProfile','streaming_subscriptions','streaming_customers','streaming_accounts','streaming_platforms','streaming_renewals','ADMIN_PLAN_MODULES.streaming','ADMIN_PLAN_DEFAULTS.streaming','YUMMY_ADMIN_PREVIEW'])if(!streamingAdmin.includes(marker))throw new Error('admin-streaming-access.js: falta '+marker);
for(const forbidden of ['subscription_price','Ventas totales','Ingresos','Ticket promedio','streaming_sales'])if(streamingAdmin.includes(forbidden))throw new Error('admin-streaming-access.js: expone métrica monetaria no requerida '+forbidden);

const streamingPreviewHotfix=readFileSync('admin-streaming-access.js','utf8');
for(const marker of ["refreshSession()","maybeSingle()","Ese negocio ya no existe o ya no pertenece a Streaming"])if(!streamingPreviewHotfix.includes(marker))throw new Error('admin-streaming-access.js: falta hotfix vista administrativa '+marker);


for(const marker of ['async function openRestaurantPanel','maybeSingle()','Ese negocio ya no existe. La lista fue actualizada.','https://streaming.yummypro.online','https://pro.yummypro.online','https://retail.yummypro.online','refreshSession()'])if(!admin.includes(marker))throw new Error('index.html: falta validación global de acceso administrativo '+marker);
