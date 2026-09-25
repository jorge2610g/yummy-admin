const { test, expect } = require('@playwright/test');

test('admin publica integración Streaming y dominio correcto', async ({ request }) => {
  const page = await request.get('/');
  expect(page.ok()).toBeTruthy();
  const html = await page.text();
  expect(html).toContain('/admin-streaming-access.js?v=1001');

  const response = await request.get('/admin-streaming-access.js?v=1001');
  expect(response.ok()).toBeTruthy();
  const body = await response.text();
  expect(body).toContain('integración Streaming v1.0.0');
  expect(body).toContain('https://streaming.yummypro.online');
  expect(body).toContain('openStreamingBusinessProfile');
  expect(body).toContain('streaming_subscriptions');
  expect(body).toContain('streaming_customers');
  expect(body).toContain('streaming_accounts');
  expect(body).toContain('streaming_platforms');
  expect(body).toContain('streaming_renewals');
  expect(body).toContain('YUMMY_ADMIN_PREVIEW');
  expect(body).toContain('refreshSession()');
  expect(body).toContain('maybeSingle()');
  expect(body).toContain('Ese negocio ya no existe o ya no pertenece a Streaming');
  expect(body).not.toContain('subscription_price');
  expect(body).not.toContain('streaming_sales');
});
