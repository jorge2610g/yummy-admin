const {
  sendJson,
  inspectAllRepositories,
  requireSuperAdmin,
  releaseConfiguration,
  backupRefName,
  createBackup,
  updateMain,
} = require('./_release-core');

function readBody(req) {
  if (req.body && typeof req.body === 'object') return Promise.resolve(req.body);
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 64 * 1024) reject(new Error('Solicitud demasiado grande.'));
    });
    req.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}); } catch (_) { reject(new Error('JSON inválido.')); }
    });
    req.on('error', reject);
  });
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return sendJson(res, 405, { error: 'Método no permitido.' });

  try {
    const body = await readBody(req);
    const action = body?.action === 'release' ? 'release' : 'dry-run';
    const repositories = await inspectAllRepositories();
    const unsafe = repositories.filter((item) => !item.safe || item.error);
    const changed = repositories.filter((item) => item.needs_release);

    if (unsafe.length) {
      return sendJson(res, 409, {
        error: 'El lanzamiento está bloqueado porque al menos un repositorio no puede promoverse por fast-forward.',
        repositories,
      });
    }

    if (action === 'dry-run') {
      return sendJson(res, 200, {
        ok: true,
        mode: 'dry-run',
        configuration: releaseConfiguration(),
        pending: changed.length,
        repositories,
        message: changed.length ? 'Diagnóstico correcto. No se modificó ninguna rama.' : 'Producción ya coincide con Pruebas. No hay cambios por lanzar.',
      });
    }

    const admin = await requireSuperAdmin(req);
    const configuration = releaseConfiguration();
    if (!configuration.github_token_configured || !configuration.release_enabled) {
      return sendJson(res, 503, {
        error: 'Los lanzamientos reales están deshabilitados. El modo seguro sigue activo.',
        configuration,
      });
    }

    if (String(body?.confirmation || '').trim().toUpperCase() !== 'LANZAR A PRODUCCION') {
      return sendJson(res, 400, { error: 'Confirmación inválida.' });
    }

    const expected = body?.expected || {};
    for (const item of repositories) {
      const exp = expected[item.key];
      if (!exp) continue;
      if (exp.main_sha !== item.main_sha || exp.staging_sha !== item.staging_sha) {
        return sendJson(res, 409, {
          error: `El repositorio ${item.label} cambió después del diagnóstico. Vuelve a preparar el lanzamiento.`,
          repositories,
        });
      }
    }

    if (!changed.length) {
      return sendJson(res, 200, { ok: true, released: false, message: 'No había cambios pendientes.', repositories });
    }

    const backupBranch = backupRefName();
    const backups = [];
    for (const item of repositories) {
      await createBackup(item.repo, item.main_sha, backupBranch);
      backups.push({ key: item.key, repo: item.repo, sha: item.main_sha, branch: backupBranch });
    }

    const promoted = [];
    try {
      for (const item of changed) {
        await updateMain(item.repo, item.staging_sha, false);
        promoted.push({ key: item.key, repo: item.repo, from: item.main_sha, to: item.staging_sha });
      }
    } catch (releaseError) {
      const rollback = [];
      for (const item of promoted.slice().reverse()) {
        try {
          await updateMain(item.repo, item.from, true);
          rollback.push({ repo: item.repo, ok: true, restored_sha: item.from });
        } catch (rollbackError) {
          rollback.push({ repo: item.repo, ok: false, error: rollbackError.message || 'Rollback falló' });
        }
      }
      return sendJson(res, 500, {
        error: 'El lanzamiento falló y se ejecutó rollback de los repositorios ya promovidos.',
        release_error: releaseError.message || 'Error de GitHub',
        promoted,
        rollback,
        backup_branch: backupBranch,
      });
    }

    return sendJson(res, 200, {
      ok: true,
      released: true,
      released_by: admin.email,
      backup_branch: backupBranch,
      promoted,
      untouched_staging: true,
      message: 'Código promovido de staging a main. No se modificaron bases de datos ni ramas staging.',
    });
  } catch (error) {
    return sendJson(res, error.status || 500, { error: error.message || 'No se pudo ejecutar el lanzamiento.' });
  }
};
