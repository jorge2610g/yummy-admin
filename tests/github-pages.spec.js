const { test, expect } = require('@playwright/test');

test('GitHub Pages Pruebas carga Admin y conecta Supabase Staging', async ({ page }) => {
  test.skip(!process.env.ADMIN_TEST_EMAIL || !process.env.ADMIN_TEST_PASSWORD, 'Credenciales de prueba no configuradas');
  const url = process.env.PAGES_TEST_URL;
  expect(url).toBeTruthy();

  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await expect(page).toHaveTitle(/Panel|Admin/i);
  await expect(page.locator('body')).toContainText('Versión v2.3.63');

  await page.locator('#email').fill(process.env.ADMIN_TEST_EMAIL);
  await page.locator('#password').fill(process.env.ADMIN_TEST_PASSWORD);
  await page.getByRole('button', { name: /Ingresar/i }).click();
  await expect(page.locator('#app')).toBeVisible({ timeout: 20000 });

  const result = await page.evaluate(async () => {
    return await releaseAuthorizedFetch('/api/release-status', { method: 'GET', headers: {} });
  });

  expect(result?.configuration?.backend).toBe('supabase');
  expect(result?.configuration?.hosting_target).toBe('github_pages');
  expect(Array.isArray(result?.repositories)).toBeTruthy();
  expect(result.repositories).toHaveLength(6);
});
