const { test, expect } = require('@playwright/test');

const TEST_URL = process.env.PAGES_TEST_URL;
const ADMIN_EMAIL = process.env.ADMIN_TEST_EMAIL;
const ADMIN_PASSWORD = process.env.ADMIN_TEST_PASSWORD;

function requireReleaseEnvironment() {
  expect(TEST_URL, 'Falta PAGES_TEST_URL para probar el sitio real de Pruebas').toBeTruthy();
  expect(ADMIN_EMAIL, 'Falta ADMIN_TEST_EMAIL: el release no puede aprobarse sin probar login real').toBeTruthy();
  expect(ADMIN_PASSWORD, 'Falta ADMIN_TEST_PASSWORD: el release no puede aprobarse sin probar login real').toBeTruthy();
}

async function login(page) {
  await page.locator('#email').fill(ADMIN_EMAIL);
  await page.locator('#password').fill(ADMIN_PASSWORD);
  await page.getByRole('button', { name: /Ingresar/i }).click();
  await expect(page.locator('#app')).toBeVisible({ timeout: 20000 });
}

async function expectMetricLoaded(page, selector) {
  const metric = page.locator(selector);
  await expect(metric).toBeVisible();
  await expect(metric).not.toHaveText('—', { timeout: 15000 });
  await expect(metric).not.toHaveText('', { timeout: 15000 });
}

test('RELEASE GATE: Admin Pruebas funciona de extremo a extremo', async ({ page, request }) => {
  requireReleaseEnvironment();

  const pageErrors = [];
  const serverErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  page.on('response', (response) => {
    if (response.status() >= 500 && response.url().startsWith(TEST_URL)) {
      serverErrors.push(`${response.status()} ${response.url()}`);
    }
  });

  await test.step('abre el Admin real de Pruebas', async () => {
    await page.goto(TEST_URL, { waitUntil: 'domcontentloaded' });
    await expect(page).toHaveTitle(/Panel|Admin/i);
    await expect(page.locator('body')).toContainText(/Versión v2\.3\.\d+/);
    await expect(page.locator('#login')).toBeVisible();
  });

  await test.step('inicia sesión con la cuenta de prueba obligatoria', async () => {
    await login(page);
  });

  await test.step('carga las métricas generales sin guiones ni errores', async () => {
    for (const selector of [
      '#metricRestaurants',
      '#metricActiveSubscriptions',
      '#metricOrders',
      '#metricTotalSales',
    ]) {
      await expectMetricLoaded(page, selector);
    }
  });

  await test.step('permite filtrar por negocio y mantiene métricas cargadas', async () => {
    const businessSelect = page.locator('#dashboardRestaurantSelect');
    await expect(businessSelect).toBeVisible();
    const optionCount = await businessSelect.locator('option').count();
    expect(optionCount).toBeGreaterThan(0);
    if (optionCount > 1) {
      await businessSelect.selectOption({ index: 1 });
      await page.waitForTimeout(800);
      await expectMetricLoaded(page, '#metricRestaurants');
      await expectMetricLoaded(page, '#metricOrders');
    }
  });

  await test.step('abre la vista 360/perfil de un negocio sin error de permisos', async () => {
    const modal = page.locator('#restaurantProfileModal');
    await expect(modal).toBeAttached();

    const restaurantId = await page.locator('button,a')
      .filter({ hasText: /360|perfil del negocio|ver perfil/i })
      .evaluateAll((nodes) => {
        for (const node of nodes) {
          const onclick = node.getAttribute('onclick') || '';
          const quoted = onclick.match(/openRestaurantProfile\(\s*['"]([^'"]+)['"]\s*\)/);
          if (quoted) return quoted[1];
          const numeric = onclick.match(/openRestaurantProfile\(\s*(\d+)\s*\)/);
          if (numeric) return numeric[1];
        }
        return null;
      });

    expect(restaurantId, 'No se encontró un negocio real para validar Perfil 360').toBeTruthy();

    await page.evaluate(async (id) => {
      if (typeof window.openRestaurantProfile !== 'function') throw new Error('openRestaurantProfile no está disponible');
      await window.openRestaurantProfile(id);
    }, restaurantId);

    await expect(modal).toBeVisible({ timeout: 10000 });
    await expect(modal).not.toContainText(/no tiene permiso|no se pudieron cargar las métricas|sin permiso/i);
  });

  await test.step('el Centro de lanzamientos responde desde Supabase', async () => {
    const result = await page.evaluate(async () => {
      return await releaseAuthorizedFetch('/api/release-status', { method: 'GET', headers: {} });
    });

    expect(result?.configuration?.backend).toBe('supabase');
    expect(result?.configuration?.hosting_target).toBe('github_pages');
    expect(Array.isArray(result?.repositories)).toBeTruthy();
    expect(result.repositories).toHaveLength(6);
  });

  await test.step('la separación Pruebas/Producción sigue protegida', async () => {
    const html = await page.content();
    expect(html).toContain('admin.yummypro.online');
    expect(html).toContain('staging-only');
    expect(html).toContain('html[data-yummy-env="production"] .staging-only');
  });

  await test.step('los dominios principales de los módulos responden', async () => {
    for (const url of [
      'https://web.yummypro.online',
      'https://retail.yummypro.online',
      'https://pro.yummypro.online',
      'https://streaming.yummypro.online',
    ]) {
      const response = await request.get(url, { failOnStatusCode: false, timeout: 20000 });
      expect(response.status(), `${url} devolvió error de servidor`).toBeLessThan(500);
    }
  });

  expect(pageErrors, `Errores JavaScript detectados: ${pageErrors.join(' | ')}`).toEqual([]);
  expect(serverErrors, `Errores 5xx detectados: ${serverErrors.join(' | ')}`).toEqual([]);
});
