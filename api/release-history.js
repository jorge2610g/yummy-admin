const {
  sendJson,
  listReleaseBackups,
  releaseConfiguration,
} = require('./_release-core');

module.exports = async function handler(req, res) {
  if (req.method !== 'GET') return sendJson(res, 405, { error: 'Método no permitido.' });
  try {
    const backups = await listReleaseBackups(10);
    return sendJson(res, 200, {
      ok: true,
      configuration: releaseConfiguration(),
      backups,
    });
  } catch (error) {
    return sendJson(res, error.status || 500, { error: error.message || 'No se pudo consultar el historial de versiones.' });
  }
};
