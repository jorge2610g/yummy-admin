const {
  sendJson,
  inspectAllRepositories,
  releaseConfiguration,
} = require('./_release-core');

module.exports = async function handler(req, res) {
  if (req.method !== 'GET') return sendJson(res, 405, { error: 'Método no permitido.' });
  try {
    const repositories = await inspectAllRepositories();
    const ready = repositories.every((item) => item.safe && !item.error);
    const pending = repositories.filter((item) => item.needs_release).length;
    return sendJson(res, 200, {
      ok: true,
      configuration: releaseConfiguration(),
      ready,
      pending,
      repositories,
    });
  } catch (error) {
    return sendJson(res, error.status || 500, { error: error.message || 'No se pudo consultar el estado del release.' });
  }
};
