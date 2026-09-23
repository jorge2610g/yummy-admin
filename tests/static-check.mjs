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

for(const marker of ['manifest.webmanifest','adminPwaInstall','installAdminPwa','adminPwaNetwork','adminPwaUpdate','admin-pwa-script-v2320','Versión v2.3.31'])if(!admin.includes(marker))throw new Error('index.html: falta PWA Admin '+marker);
for(const marker of ['settingsRestaurantSelect','changeSettingsRestaurant','settingsBusinessBadge','demoApiInheritanceCard','demoApiInheritanceToggle','toggleDemoApiInheritance','set_demo_business_api_inheritance','use_demo_api_defaults','is_demo','API global de demos'])if(!admin.includes(marker))throw new Error('index.html: falta configuración de APIs para demos '+marker);

if(!admin.includes('/manifest.webmanifest?v=2320'))throw new Error('index.html: falta manifest PWA admin versionado');

for(const marker of ['adminObservabilityPanel','loadAdminObservability','admin_observability_summary','admin_plan_recommendations','obsSystemErrors','obsUserErrors','obsRecommendations','obsRecentReports'])if(!admin.includes(marker))throw new Error('index.html: falta observabilidad admin '+marker);

for(const marker of ['rbusinessType','business_type','adminRetailSummary','loadAdminRetailSummary','openRetailBusinessProfile','retail_products','retail_sales','retail_purchases','Restaurantes activos','Negocios activos'])if(!admin.includes(marker))throw new Error('index.html: falta infraestructura retail admin '+marker);

for(const marker of ['retail_returns','refunded_amount','refund_status','Venta neta','Devuelto'])if(!admin.includes(marker))throw new Error('index.html: falta devolución retail admin '+marker);

for(const marker of ['retail_online_orders','Pedidos online activos','Venta online','Ver tienda online','retail_orders','Versión v2.3.31'])if(!admin.includes(marker))throw new Error('index.html: falta tienda online retail admin '+marker);

for(const marker of ['admin-mobile-information-v2325','mobile-section-switcher','restaurantBusinessTypeFilter','subscriptionBusinessTypeFilter','subscriptionPaymentBusinessTypeFilter','staffBusinessTypeFilter','customerBusinessTypeFilter','planBusinessType','business_type','retail_orders','retail_pos','retail_products','retail_suppliers','retail_purchases','Métodos de cobro'])if(!admin.includes(marker))throw new Error('index.html: falta navegación/filtros móviles '+marker);
