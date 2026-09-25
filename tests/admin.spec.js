const {test,expect}=require('@playwright/test');
test('carga el acceso administrativo sin errores críticos',async({page})=>{const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto('/',{waitUntil:'domcontentloaded'});await expect(page).toHaveTitle(/Panel|Admin/i);await expect(page.locator('#login')).toBeAttached();expect(errors).toEqual([])});
test('permite iniciar sesión con cuenta de prueba',async({page})=>{test.skip(!process.env.ADMIN_TEST_EMAIL||!process.env.ADMIN_TEST_PASSWORD,'Credenciales de prueba no configuradas');await page.goto('/');await page.locator('#email').fill(process.env.ADMIN_TEST_EMAIL);await page.locator('#password').fill(process.env.ADMIN_TEST_PASSWORD);await page.getByRole('button',{name:/Ingresar/i}).click();await expect(page.locator('#app')).toBeVisible({timeout:15000});await expect(page.locator('#metricRestaurants')).not.toHaveText('—')});
test('muestra los módulos administrativos actuales y el resumen filtrable',async({page})=>{await page.setViewportSize({width:390,height:844});await page.goto('/');for(const id of ['#customers','#restaurantProfileModal','#adminSalesChart','#metricRestaurants','#metricActiveSubscriptions','#metricOrders','#metricTotalSales','#dashboardRestaurantSelect'])await expect(page.locator(id)).toBeAttached();const tabs=page.locator('#adminSideMenu .tab');await expect(tabs).toHaveCount(8);for(const tab of ['orders','kitchenAdmin','financeAdmin','inventoryAdmin','promotionsAdmin','reviewsAdmin'])await expect(page.locator('#adminSideMenu [data-tab="'+tab+'"]')).toHaveCount(0)});

test('incluye historial global de pagos de suscripción',async({page})=>{await page.goto('/');await expect(page.locator('#adminSubscriptionPaymentHistory')).toBeAttached();await expect(page.locator('#subscriptionPaymentHistoryCard')).toBeAttached()});

test('incluye configuración de Flow Chile',async({page})=>{await page.goto('/');await expect(page.locator('#flowCredentialsCard')).toBeAttached();await expect(page.locator('#subscriptionFlowApiKey')).toBeAttached();await expect(page.locator('#subscriptionFlowEnvironment')).toBeAttached()});

test('permite configurar precio y meses de regalo del plan anual',async({page})=>{await page.goto('/');const html=await page.content();expect(html).toContain('planAnnualEnabled');expect(html).toContain('planAnnualBonusMonths');expect(html).toContain('planAnnualAmount');expect(html).toContain('updateAnnualPlanPreview')});


test('valida negocio antes de abrir cualquier vertical',async({request})=>{
  const response=await request.get('/');
  expect(response.ok()).toBeTruthy();
  const html=await response.text();
  expect(html).toContain('Versión v2.3.62');
  expect(html).toContain('maybeSingle()');
  expect(html).toContain('Ese negocio ya no existe.');
  expect(html).toContain('create-admin-preview-login');
  expect(html).toContain('admin_token_hash');
  expect(html).toContain('https://streaming.yummypro.online');
  expect(html).toContain('https://pro.yummypro.online');
  expect(html).toContain('https://retail.yummypro.online');
  expect(html).toContain('refreshSession()');
});


test('configuración muestra switch de credenciales del administrador', async ({ page }) => {
  await page.goto('/');
  const html=await page.content();
  expect(html).toContain('settingsAdminPaymentTestModeToggle');
  expect(html).toContain('Credenciales del administrador para pruebas');
});


test('Mercado Pago usa un solo switch y separa VeriPagos demo', async ({ page }) => {
  await page.goto('/');
  const html=await page.content();
  expect((html.match(/id=\"settingsAdminPaymentTestModeToggle\"/g)||[]).length).toBe(1);
  expect(html).not.toContain('adminPaymentTestModeToggle');
  expect(html).toContain('QR Bolivia / VeriPagos del demo');
  expect(html).toContain('No modifica Mercado Pago');
});


test('Centro de lanzamientos responde desde Supabase sin Vercel',async({page})=>{
  test.skip(!process.env.ADMIN_TEST_EMAIL||!process.env.ADMIN_TEST_PASSWORD,'Credenciales de prueba no configuradas');
  await page.goto('/');
  await page.locator('#email').fill(process.env.ADMIN_TEST_EMAIL);
  await page.locator('#password').fill(process.env.ADMIN_TEST_PASSWORD);
  await page.getByRole('button',{name:/Ingresar/i}).click();
  await expect(page.locator('#app')).toBeVisible({timeout:15000});
  const status=await page.evaluate(async()=>await releaseAuthorizedFetch('/api/release-status',{method:'GET',headers:{}}));
  expect(status?.configuration?.backend).toBe('supabase');
  expect(status?.configuration?.hosting_target).toBe('github_pages');
  expect(Array.isArray(status?.repositories)).toBeTruthy();
  expect(status.repositories).toHaveLength(6);
});
