const {test,expect}=require('@playwright/test');
test('carga el acceso administrativo sin errores críticos',async({page})=>{const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto('/',{waitUntil:'domcontentloaded'});await expect(page).toHaveTitle(/Panel|Admin/i);await expect(page.locator('#login')).toBeAttached();expect(errors).toEqual([])});
test('permite iniciar sesión con cuenta de prueba',async({page})=>{test.skip(!process.env.ADMIN_TEST_EMAIL||!process.env.ADMIN_TEST_PASSWORD,'Credenciales de prueba no configuradas');await page.goto('/');await page.locator('#email').fill(process.env.ADMIN_TEST_EMAIL);await page.locator('#password').fill(process.env.ADMIN_TEST_PASSWORD);await page.getByRole('button',{name:/Ingresar/i}).click();await expect(page.locator('#app')).toBeVisible({timeout:15000});await expect(page.locator('#metricRestaurants')).not.toHaveText('—')});
test('muestra solo los seis módulos administrativos y el resumen filtrable',async({page})=>{await page.setViewportSize({width:390,height:844});await page.goto('/');for(const id of ['#customers','#restaurantProfileModal','#adminSalesChart','#metricRestaurants','#metricActiveSubscriptions','#metricOrders','#metricTotalSales','#dashboardRestaurantSelect'])await expect(page.locator(id)).toBeAttached();const tabs=page.locator('#adminSideMenu .tab');await expect(tabs).toHaveCount(6);for(const tab of ['orders','kitchenAdmin','financeAdmin','inventoryAdmin','promotionsAdmin','reviewsAdmin'])await expect(page.locator('#adminSideMenu [data-tab="'+tab+'"]')).toHaveCount(0)});

test('incluye historial global de pagos de suscripción',async({page})=>{await page.goto('/');await expect(page.locator('#adminSubscriptionPaymentHistory')).toBeAttached();await expect(page.locator('#subscriptionPaymentHistoryCard')).toBeAttached()});

test('incluye configuración de Flow Chile',async({page})=>{await page.goto('/');await expect(page.locator('#flowCredentialsCard')).toBeAttached();await expect(page.locator('#subscriptionFlowApiKey')).toBeAttached();await expect(page.locator('#subscriptionFlowEnvironment')).toBeAttached()});

test('permite configurar precio y meses de regalo del plan anual',async({page})=>{await page.goto('/');const html=await page.content();expect(html).toContain('planAnnualEnabled');expect(html).toContain('planAnnualBonusMonths');expect(html).toContain('planAnnualAmount');expect(html).toContain('updateAnnualPlanPreview')});

async function diagnosePwaInstallability(page,context,url,label){
  await page.goto(url,{waitUntil:'domcontentloaded'});
  await page.waitForTimeout(2200);
  let sw={supported:false};
  for(let attempt=0;attempt<4;attempt++){
    try{
      sw=await page.evaluate(async()=>{
        if(!('serviceWorker' in navigator))return {supported:false};
        const regs=await navigator.serviceWorker.getRegistrations();
        return {
          supported:true,
          controller:!!navigator.serviceWorker.controller,
          registrations:regs.map(r=>({scope:r.scope,active:!!r.active,waiting:!!r.waiting,installing:!!r.installing}))
        };
      });
      break;
    }catch(e){
      await page.waitForLoadState('domcontentloaded').catch(()=>{});
      await page.waitForTimeout(700);
    }
  }
  await page.waitForTimeout(500);
  const cdp=await context.newCDPSession(page);
  const manifest=await cdp.send('Page.getAppManifest');
  const installability=await cdp.send('Page.getInstallabilityErrors');
  const report={label,url,sw,manifestUrl:manifest.url,manifestErrors:manifest.errors||[],installabilityErrors:installability.installabilityErrors||[]};
  console.log('PWA_DIAGNOSTIC '+JSON.stringify(report));
  expect(report.manifestErrors,JSON.stringify(report)).toEqual([]);
  expect(report.installabilityErrors,JSON.stringify(report)).toEqual([]);
}

test('diagnóstico PWA instalable: administrador',async({page,context})=>{await diagnosePwaInstallability(page,context,'/','administrador')});
