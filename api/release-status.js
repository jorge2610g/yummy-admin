const {
  sendJson,
  inspectAllRepositories,
  inspectAllRepositoryHealth,
  releaseConfiguration,
} = require('./_release-core');

module.exports = async function handler(req, res) {
  if (req.method !== 'GET') return sendJson(res, 405, { error: 'Método no permitido.' });
  try {
    const configuration = releaseConfiguration();
    let repositories = await inspectAllRepositories();
    const healthRequired = configuration.github_token_configured && configuration.release_enabled;
    if (healthRequired) repositories = await inspectAllRepositoryHealth(repositories);
    const ready = repositories.every((item) => item.safe && !item.error && (!healthRequired || item.ci_ready));
    const pending = repositories.filter((item) => item.needs_release).length;
    return sendJson(res, 200, {
      ok: true,
      configuration,
      health_required: healthRequired,
      ready,
      pending,
      repositories,
    });
  } catch (error) {
    return sendJson(res, error.status || 500, { error: error.message || 'No se pudo consultar el estado del release.' });
  }
};
