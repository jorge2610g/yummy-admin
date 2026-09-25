const {
  REPOSITORIES,
  sendJson,
  getBranchSha,
  requireSuperAdmin,
  releaseConfiguration,
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

function rollbackSafetyBranch() {
  return 'backup/rollback-safety-' + new Date().toISOString().replace(/[:.]/g, '-').replace('T', '-').replace('Z', '');
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return sendJson(res, 405, { error: 'Método no permitido.' });

  try {
    const admin = await requireSuperAdmin(req);
    const configuration = releaseConfiguration();
    if (!configuration.github_token_configured || !configuration.release_enabled) {
      return sendJson(res, 503, {
        error: 'La restauración real está deshabilitada mientras el modo seguro siga activo.',
        configuration,
      });
    }

    const body = await readBody(req);
    const backupBranch = String(body?.backup_branch || '').trim();
    if (!backupBranch.startsWith('backup/release-')) {
      return sendJson(res, 400, { error: 'El respaldo seleccionado no pertenece al historial de lanzamientos.' });
    }
    if (String(body?.confirmation || '').trim().toUpperCase() !== 'RESTAURAR PRODUCCION') {
      return sendJson(res, 400, { error: 'Confirmación inválida.' });
    }

    const states = [];
    for (const item of REPOSITORIES) {
      const [mainSha, targetSha] = await Promise.all([
        getBranchSha(item.repo, 'main'),
        getBranchSha(item.repo, backupBranch),
      ]);
      if (!mainSha || !targetSha) {
        return sendJson(res, 409, {
          error: `No se encontró el respaldo completo para ${item.label}.`,
          repository: item.repo,
        });
      }
      states.push({ ...item, main_sha: mainSha, target_sha: targetSha });
    }

    const safetyBranch = rollbackSafetyBranch();
    for (const item of states) {
      await createBackup(item.repo, item.main_sha, safetyBranch);
    }

    const restored = [];
    try {
      for (const item of states) {
        await updateMain(item.repo, item.target_sha, true);
        restored.push({ repo: item.repo, from: item.main_sha, to: item.target_sha });
      }
    } catch (restoreError) {
      const recovery = [];
      for (const item of restored.slice().reverse()) {
        try {
          await updateMain(item.repo, item.from, true);
          recovery.push({ repo: item.repo, ok: true, restored_sha: item.from });
        } catch (recoveryError) {
          recovery.push({ repo: item.repo, ok: false, error: recoveryError.message || 'No se pudo recuperar main.' });
        }
      }
      return sendJson(res, 500, {
        error: 'La restauración falló y se intentó recuperar el estado anterior.',
        restore_error: restoreError.message || 'Error de GitHub',
        recovery,
        safety_branch: safetyBranch,
      });
    }

    return sendJson(res, 200, {
      ok: true,
      restored: true,
      restored_by: admin.email,
      source_backup: backupBranch,
      safety_branch: safetyBranch,
      repositories: restored,
      untouched_staging: true,
      message: 'Producción fue restaurada al respaldo seleccionado. Las ramas staging no se modificaron.',
    });
  } catch (error) {
    return sendJson(res, error.status || 500, { error: error.message || 'No se pudo restaurar Producción.' });
  }
};
