import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const REPOSITORIES = [
  { key: "admin", label: "Admin", repo: "jorge2610g/yummy-admin", test_repo: "jorge2610g/yummy-admin-pruebas" },
  { key: "restaurante", label: "Restaurante", repo: "jorge2610g/yummy-restaurante", test_repo: "jorge2610g/yummy-restaurante-pruebas" },
  { key: "retail", label: "Retail", repo: "jorge2610g/yummy-retail", test_repo: "jorge2610g/yummy-retail-pruebas" },
  { key: "profesionales", label: "Profesionales", repo: "jorge2610g/yummy-profesionales", test_repo: "jorge2610g/yummy-profesionales-pruebas" },
  { key: "streaming", label: "Streaming", repo: "jorge2610g/yummy-streaming", test_repo: "jorge2610g/yummy-streaming-pruebas" },
  { key: "cliente", label: "Cliente", repo: "jorge2610g/mipagina", test_repo: "jorge2610g/yummy-cliente-pruebas" },
];

const GH_API = "https://api.github.com";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function env(name: string) {
  return String(Deno.env.get(name) || "").trim();
}

function response(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function publishableKey() {
  try {
    const keys = JSON.parse(env("SUPABASE_PUBLISHABLE_KEYS") || "{}");
    if (keys?.default) return String(keys.default);
  } catch (_) {}
  return env("SUPABASE_ANON_KEY");
}

async function requireSuperAdmin(req: Request) {
  const authorization = String(req.headers.get("Authorization") || "");
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) throw Object.assign(new Error("Sesión de administrador requerida."), { status: 401 });

  const supabaseUrl = env("SUPABASE_URL");
  const key = publishableKey();
  if (!supabaseUrl || !key) {
    throw Object.assign(new Error("Supabase no tiene disponible la clave pública del proyecto."), { status: 503 });
  }

  const headers = { apikey: key, Authorization: authorization };
  const userResponse = await fetch(`${supabaseUrl.replace(/\/$/, "")}/auth/v1/user`, { headers });
  if (!userResponse.ok) throw Object.assign(new Error("La sesión del administrador no es válida o expiró."), { status: 401 });
  const user = await userResponse.json();
  if (!user?.id) throw Object.assign(new Error("No se pudo identificar al administrador."), { status: 401 });

  const adminResponse = await fetch(
    `${supabaseUrl.replace(/\/$/, "")}/rest/v1/admin_users?user_id=eq.${encodeURIComponent(user.id)}&select=user_id&limit=1`,
    { headers }
  );
  if (!adminResponse.ok) {
    throw Object.assign(new Error("No se pudo verificar el permiso de administrador global."), { status: 403 });
  }
  const rows = await adminResponse.json();
  if (!Array.isArray(rows) || !rows.length) {
    throw Object.assign(new Error("Solo el administrador global puede usar el Centro de lanzamientos."), { status: 403 });
  }
  return { id: user.id, email: user.email || null };
}

function githubHeaders(write = false) {
  const token = env("YUMMY_RELEASE_GITHUB_TOKEN");
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "YummyPro-Release-Center-Supabase",
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (write) headers["Content-Type"] = "application/json";
  return headers;
}

async function githubRequest(path: string, options: RequestInit = {}) {
  const res = await fetch(`${GH_API}${path}`, {
    ...options,
    headers: { ...githubHeaders(!!options.body), ...((options.headers as Record<string, string>) || {}) },
  });
  const raw = await res.text();
  let data: any = null;
  try { data = raw ? JSON.parse(raw) : null; } catch (_) { data = { message: raw || "Respuesta inválida de GitHub" }; }
  if (!res.ok) {
    const error: any = new Error(data?.message || `GitHub respondió ${res.status}`);
    error.status = res.status;
    error.data = data;
    throw error;
  }
  return data;
}

async function compareBranches(repo: string) {
  return githubRequest(`/repos/${repo}/compare/main...staging`);
}

async function getBranchSha(repo: string, branch: string) {
  const data = await githubRequest(`/repos/${repo}/git/ref/heads/${branch}`);
  return data?.object?.sha || null;
}

async function inspectRepository(item: any) {
  const comparison = await compareBranches(item.repo);
  const status = String(comparison?.status || "unknown");
  const mainSha = comparison?.base_commit?.sha || null;
  const commits = Array.isArray(comparison?.commits) ? comparison.commits : [];
  const stagingSha = status === "identical"
    ? mainSha
    : commits.at(-1)?.sha || comparison?.merge_base_commit?.sha || null;
  const aheadBy = Number(comparison?.ahead_by || 0);
  const behindBy = Number(comparison?.behind_by || 0);
  const safe = status === "identical" || (status === "ahead" && behindBy === 0);
  return {
    ...item,
    main_sha: mainSha,
    staging_sha: stagingSha,
    status,
    ahead_by: aheadBy,
    behind_by: behindBy,
    changed_files: Array.isArray(comparison?.files) ? comparison.files.length : 0,
    safe,
    needs_release: status === "ahead" && aheadBy > 0,
  };
}

async function inspectAllRepositories() {
  const results: any[] = [];
  for (const item of REPOSITORIES) {
    try { results.push(await inspectRepository(item)); }
    catch (error) {
      results.push({ ...item, safe: false, needs_release: false, error: error instanceof Error ? error.message : "No se pudo inspeccionar el repositorio" });
    }
  }
  return results;
}

async function inspectQuality(item: any) {
  if (!item?.staging_sha || item.error) return { ...item, quality_ready: false, quality: "unavailable", quality_url: null };
  const checks = await githubRequest(`/repos/${item.repo}/commits/${item.staging_sha}/check-runs`);
  const quality = latestCheckByName(checks?.check_runs || [], "quality");
  const ok = quality?.status === "completed" && ["success", "neutral", "skipped"].includes(String(quality?.conclusion || ""));
  return {
    ...item,
    quality_ready: ok,
    quality: quality ? (quality.status === "completed" ? quality.conclusion : quality.status) : "missing",
    quality_url: quality?.details_url || null,
    quality_started_at: quality?.started_at || null,
    quality_completed_at: quality?.completed_at || null,
  };
}

function latestCheckByName(checks: any[], name: string) {
  return (checks || [])
    .filter((check: any) => check?.name === name)
    .sort((a: any, b: any) => String(b?.completed_at || b?.started_at || "").localeCompare(String(a?.completed_at || a?.started_at || "")))[0] || null;
}

async function inspectProductionDeployment(item: any) {
  const synced = !!item?.main_sha && !!item?.staging_sha && item.main_sha === item.staging_sha;
  if (!synced || item.error) {
    return { ...item, production_code_synced: synced, production_deploy_ready: false, production_deploy: synced ? "checking" : "waiting" };
  }
  const checks = await githubRequest(`/repos/${item.repo}/commits/${item.main_sha}/check-runs`);
  const all = checks?.check_runs || [];
  const deploy = latestCheckByName(all, "deploy") || latestCheckByName(all, "build") || latestCheckByName(all, "report-build-status");
  const status = deploy ? (deploy.status === "completed" ? String(deploy.conclusion || "unknown") : String(deploy.status || "unknown")) : "pending";
  const ready = deploy?.status === "completed" && ["success", "neutral", "skipped"].includes(String(deploy?.conclusion || ""));
  return {
    ...item,
    production_code_synced: true,
    production_deploy_ready: ready,
    production_deploy: status,
    production_deploy_url: deploy?.details_url || null,
  };
}

async function inspectAllProductionDeployment(repositories: any[]) {
  const results: any[] = [];
  for (const item of repositories) {
    try { results.push(await inspectProductionDeployment(item)); }
    catch (error) {
      results.push({
        ...item,
        production_code_synced: item?.main_sha === item?.staging_sha,
        production_deploy_ready: false,
        production_deploy: "error",
        production_deploy_error: error instanceof Error ? error.message : "No se pudo verificar el despliegue de Producción",
      });
    }
  }
  return results;
}

async function inspectAllQuality(repositories: any[]) {
  const results: any[] = [];
  for (const item of repositories) {
    try { results.push(await inspectQuality(item)); }
    catch (error) {
      results.push({ ...item, quality_ready: false, quality: "error", quality_error: error instanceof Error ? error.message : "No se pudo verificar Calidad" });
    }
  }
  return results;
}

function configuration() {
  return {
    backend: "supabase",
    hosting_target: "github_pages",
    github_token_configured: !!env("YUMMY_RELEASE_GITHUB_TOKEN"),
    release_enabled: env("YUMMY_RELEASE_ENABLED").toLowerCase() === "true",
  };
}

function backupRefName() {
  return `backup/release-${new Date().toISOString().replace(/[:.]/g, "-").replace("T", "-").replace("Z", "")}`;
}

function rollbackSafetyBranch() {
  return `backup/rollback-safety-${new Date().toISOString().replace(/[:.]/g, "-").replace("T", "-").replace("Z", "")}`;
}

async function createBackup(repo: string, sha: string, branchName: string) {
  return githubRequest(`/repos/${repo}/git/refs`, {
    method: "POST",
    body: JSON.stringify({ ref: `refs/heads/${branchName}`, sha }),
  });
}

async function updateMain(repo: string, sha: string, force = false) {
  return githubRequest(`/repos/${repo}/git/refs/heads/main`, {
    method: "PATCH",
    body: JSON.stringify({ sha, force }),
  });
}

async function updateStaging(repo: string, sha: string, force = true) {
  return githubRequest(`/repos/${repo}/git/refs/heads/staging`, {
    method: "PATCH",
    body: JSON.stringify({ sha, force }),
  });
}

function emergencyBackupRefName() {
  return `backup/emergency-staging-${new Date().toISOString().replace(/[:.]/g, "-").replace("T", "-").replace("Z", "")}`;
}

function repositoryByKey(key: string) {
  return REPOSITORIES.find((item) => item.key === key) || null;
}

async function dispatchWorkflow(repo: string, workflow: string, ref: string) {
  await githubRequest(`/repos/${repo}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`, {
    method: "POST",
    body: JSON.stringify({ ref }),
  });
  return true;
}

async function latestStableQuality(repo: string) {
  const data = await githubRequest(`/repos/${repo}/actions/workflows/quality.yml/runs?branch=staging&status=success&per_page=20`);
  const runs = Array.isArray(data?.workflow_runs) ? data.workflow_runs : [];
  const run = runs.find((row: any) => row?.head_sha && row?.conclusion === "success") || null;
  return run ? {
    sha: run.head_sha,
    run_id: run.id,
    url: run.html_url || null,
    created_at: run.created_at || null,
    updated_at: run.updated_at || null,
  } : null;
}

async function emergencyModuleState(item: any) {
  const currentSha = await getBranchSha(item.repo, "staging");
  let stable: any = null;
  try { stable = await latestStableQuality(item.repo); } catch (_) {}
  let quality: any = null;
  try {
    const base = { ...item, staging_sha: currentSha };
    quality = await inspectQuality(base);
  } catch (_) {}
  return {
    key: item.key,
    label: item.label,
    repo: item.repo,
    test_repo: item.test_repo,
    staging_sha: currentSha,
    quality: quality?.quality || "unavailable",
    quality_ready: !!quality?.quality_ready,
    quality_url: quality?.quality_url || null,
    stable_sha: stable?.sha || null,
    stable_url: stable?.url || null,
    stable_at: stable?.updated_at || stable?.created_at || null,
  };
}

async function emergencyTargets(key: string) {
  if (key === "all") return [...REPOSITORIES];
  const item = repositoryByKey(key);
  if (!item) throw Object.assign(new Error("Módulo de Pruebas no reconocido."), { status: 400 });
  return [item];
}

function releaseBranchDate(branch: string) {
  const match = String(branch || "").match(/^backup\/release-(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})/);
  if (!match) return null;
  const [, year, month, day, hour, minute, second] = match;
  return `${year}-${month}-${day}T${hour}:${minute}:${second}Z`;
}

async function listReleaseBackups(limit = 10) {
  const data = await githubRequest(`/repos/${REPOSITORIES[0].repo}/git/matching-refs/heads/backup/release-`);
  return (Array.isArray(data) ? data : [])
    .map((ref: any) => {
      const branch = String(ref?.ref || "").replace(/^refs\/heads\//, "");
      return { branch, admin_sha: ref?.object?.sha || null, created_at: releaseBranchDate(branch) };
    })
    .filter((item: any) => item.branch.startsWith("backup/release-"))
    .sort((a: any, b: any) => String(b.branch).localeCompare(String(a.branch)))
    .slice(0, limit);
}

async function handleStatus() {
  let repositories = await inspectAllRepositories();
  repositories = await inspectAllQuality(repositories);
  repositories = await inspectAllProductionDeployment(repositories);
  return {
    ok: true,
    configuration: configuration(),
    ready: repositories.every((item) => item.safe && !item.error && item.quality_ready),
    pending: repositories.filter((item) => item.needs_release).length,
    production_live: repositories.every((item) => item.production_code_synced && item.production_deploy_ready),
    repositories,
  };
}

async function handleDryRun() {
  const cfg = configuration();
  let repositories = await inspectAllRepositories();
  const unsafe = repositories.filter((item) => !item.safe || item.error);
  if (cfg.release_enabled && cfg.github_token_configured) {
    repositories = await inspectAllQuality(repositories);
  }
  const qualityBlocked = cfg.release_enabled && cfg.github_token_configured
    ? repositories.filter((item) => !item.quality_ready)
    : [];
  return {
    ok: unsafe.length === 0 && qualityBlocked.length === 0,
    mode: "dry-run",
    configuration: cfg,
    ready: unsafe.length === 0 && qualityBlocked.length === 0,
    pending: repositories.filter((item) => item.needs_release).length,
    repositories,
    message: unsafe.length || qualityBlocked.length
      ? "El lanzamiento no está listo todavía."
      : "Diagnóstico correcto. No se modificó ninguna rama.",
  };
}

async function handleRelease(body: any, admin: any) {
  const cfg = configuration();
  if (!cfg.github_token_configured || !cfg.release_enabled) {
    return { status: 503, body: { error: "Los lanzamientos reales están deshabilitados. El modo seguro sigue activo.", configuration: cfg } };
  }

  let repositories = await inspectAllRepositories();
  const unsafe = repositories.filter((item) => !item.safe || item.error);
  if (unsafe.length) return { status: 409, body: { error: "Hay repositorios que no pueden promoverse por fast-forward.", repositories } };

  repositories = await inspectAllQuality(repositories);
  const unhealthy = repositories.filter((item) => !item.quality_ready);
  if (unhealthy.length) return { status: 409, body: { error: "El lanzamiento está bloqueado porque Calidad no está en verde para todos los módulos.", repositories } };

  if (String(body?.confirmation || "").trim().toUpperCase() !== "LANZAR A PRODUCCION") {
    return { status: 400, body: { error: "Confirmación inválida." } };
  }

  const expected = body?.expected || {};
  for (const item of repositories) {
    const exp = expected[item.key];
    if (!exp?.main_sha || !exp?.staging_sha) {
      return { status: 400, body: { error: `Falta el snapshot esperado para ${item.label}. Vuelve a preparar el lanzamiento.`, repositories } };
    }
    if (exp.main_sha !== item.main_sha || exp.staging_sha !== item.staging_sha) {
      return { status: 409, body: { error: `El repositorio ${item.label} cambió después del diagnóstico. Vuelve a preparar el lanzamiento.`, repositories } };
    }
  }

  // Revalidación autoritativa inmediatamente antes de crear respaldos o mover main.
  // Nunca confiamos solo en los SHA derivados del compare endpoint.
  const authoritative: any[] = [];
  for (const item of repositories) {
    const [mainSha, stagingSha] = await Promise.all([
      getBranchSha(item.repo, "main"),
      getBranchSha(item.repo, "staging"),
    ]);
    const exp = expected[item.key];
    if (!mainSha || !stagingSha || mainSha !== exp.main_sha || stagingSha !== exp.staging_sha) {
      return {
        status: 409,
        body: {
          error: `Las referencias reales de ${item.label} cambiaron después del diagnóstico. No se modificó Producción; vuelve a preparar el lanzamiento.`,
          repository: item.repo,
          expected: { main_sha: exp.main_sha, staging_sha: exp.staging_sha },
          current: { main_sha: mainSha, staging_sha: stagingSha },
        },
      };
    }
    authoritative.push({ ...item, main_sha: mainSha, staging_sha: stagingSha });
  }
  repositories = authoritative;

  const changed = repositories.filter((item) => item.needs_release);
  if (!changed.length) return { status: 200, body: { ok: true, released: false, message: "No había cambios pendientes.", repositories } };

  const backupBranch = backupRefName();
  for (const item of repositories) await createBackup(item.repo, item.main_sha, backupBranch);

  const promoted: any[] = [];
  try {
    for (const item of changed) {
      await updateMain(item.repo, item.staging_sha, false);
      promoted.push({ key: item.key, repo: item.repo, from: item.main_sha, to: item.staging_sha });
    }
  } catch (releaseError) {
    const rollback: any[] = [];
    for (const item of promoted.slice().reverse()) {
      try { await updateMain(item.repo, item.from, true); rollback.push({ repo: item.repo, ok: true, restored_sha: item.from }); }
      catch (rollbackError) { rollback.push({ repo: item.repo, ok: false, error: rollbackError instanceof Error ? rollbackError.message : "Rollback falló" }); }
    }
    return { status: 500, body: { error: "El lanzamiento falló y se ejecutó rollback.", promoted, rollback, backup_branch: backupBranch } };
  }

  return { status: 200, body: { ok: true, released: true, released_by: admin.email, backup_branch: backupBranch, promoted, untouched_staging: true, message: "Código promovido de staging a main. No se modificaron bases de datos ni ramas staging." } };
}

async function handleEmergencyStatus() {
  const modules: any[] = [];
  for (const item of REPOSITORIES) {
    try { modules.push(await emergencyModuleState(item)); }
    catch (error) {
      modules.push({
        key: item.key,
        label: item.label,
        repo: item.repo,
        test_repo: item.test_repo,
        quality: "error",
        quality_ready: false,
        error: error instanceof Error ? error.message : "No se pudo revisar este módulo.",
      });
    }
  }
  return {
    ok: true,
    environment: "staging",
    production_untouched: true,
    modules,
    all_green: modules.every((item) => item.quality_ready),
  };
}

async function handleRetryQuality(body: any) {
  const key = String(body?.key || "all");
  const targets = await emergencyTargets(key);
  const dispatched: any[] = [];
  for (const item of targets) {
    await dispatchWorkflow(item.repo, "quality.yml", "staging");
    dispatched.push({ key: item.key, repo: item.repo, workflow: "quality.yml", ref: "staging" });
  }
  return {
    ok: true,
    production_untouched: true,
    dispatched,
    message: targets.length === 1 ? "Validación de Pruebas reiniciada." : "Validaciones de todos los módulos de Pruebas reiniciadas.",
  };
}

async function handleRepublishTests(body: any) {
  const key = String(body?.key || "all");
  const targets = await emergencyTargets(key);
  const dispatched: any[] = [];
  for (const item of targets) {
    await dispatchWorkflow(item.test_repo, "deploy-staging-pages.yml", "main");
    dispatched.push({ key: item.key, repo: item.test_repo, workflow: "deploy-staging-pages.yml", ref: "main" });
  }
  return {
    ok: true,
    production_untouched: true,
    dispatched,
    message: targets.length === 1 ? "Republicación de Pruebas iniciada." : "Republicación de todos los sitios de Pruebas iniciada.",
  };
}

async function handleRestoreStableTests(body: any, admin: any) {
  const key = String(body?.key || "all");
  const confirmation = String(body?.confirmation || "").trim().toUpperCase();
  if (confirmation !== "RESTAURAR PRUEBAS") {
    return { status: 400, body: { error: "Confirmación inválida. Escribe RESTAURAR PRUEBAS." } };
  }
  const targets = await emergencyTargets(key);
  const backupBranch = emergencyBackupRefName();
  const states: any[] = [];

  for (const item of targets) {
    const [currentSha, stable] = await Promise.all([
      getBranchSha(item.repo, "staging"),
      latestStableQuality(item.repo),
    ]);
    if (!currentSha) return { status: 409, body: { error: `No se pudo leer staging de ${item.label}.` } };
    if (!stable?.sha) return { status: 409, body: { error: `No existe una validación estable anterior para ${item.label}.` } };
    states.push({ ...item, current_sha: currentSha, stable_sha: stable.sha, stable_url: stable.url });
  }

  for (const item of states) {
    try { await createBackup(item.repo, item.current_sha, backupBranch); }
    catch (error) {
      return {
        status: 409,
        body: {
          error: `No se pudo crear el respaldo de seguridad de ${item.label}. No se modificó staging.`,
          detail: error instanceof Error ? error.message : "Error de respaldo",
        },
      };
    }
  }

  const restored: any[] = [];
  try {
    for (const item of states) {
      if (item.current_sha !== item.stable_sha) await updateStaging(item.repo, item.stable_sha, true);
      restored.push({
        key: item.key,
        repo: item.repo,
        from: item.current_sha,
        to: item.stable_sha,
        changed: item.current_sha !== item.stable_sha,
      });
    }
  } catch (restoreError) {
    const recovery: any[] = [];
    for (const item of restored.slice().reverse()) {
      if (!item.changed) continue;
      try { await updateStaging(item.repo, item.from, true); recovery.push({ repo: item.repo, ok: true }); }
      catch (error) { recovery.push({ repo: item.repo, ok: false, error: error instanceof Error ? error.message : "Recuperación falló" }); }
    }
    return {
      status: 500,
      body: {
        error: "La restauración de Pruebas falló y se intentó recuperar el staging anterior.",
        recovery,
        backup_branch: backupBranch,
      },
    };
  }

  const dispatched: any[] = [];
  for (const item of states) {
    try { await dispatchWorkflow(item.repo, "quality.yml", "staging"); dispatched.push({ key: item.key, quality: true }); } catch (_) {}
    try { await dispatchWorkflow(item.test_repo, "deploy-staging-pages.yml", "main"); } catch (_) {}
  }

  return {
    status: 200,
    body: {
      ok: true,
      restored: true,
      restored_by: admin.email,
      backup_branch: backupBranch,
      repositories: restored,
      dispatched,
      production_untouched: true,
      message: targets.length === 1
        ? "El módulo de Pruebas fue restaurado a su última validación estable."
        : "Todos los módulos de Pruebas fueron restaurados a su última validación estable.",
    },
  };
}

async function handleRollback(body: any, admin: any) {
  const cfg = configuration();
  if (!cfg.github_token_configured || !cfg.release_enabled) {
    return { status: 503, body: { error: "La restauración real está deshabilitada mientras el modo seguro siga activo.", configuration: cfg } };
  }

  const backupBranch = String(body?.backup_branch || "").trim();
  if (!backupBranch.startsWith("backup/release-")) return { status: 400, body: { error: "El respaldo seleccionado no pertenece al historial de lanzamientos." } };
  if (String(body?.confirmation || "").trim().toUpperCase() !== "RESTAURAR PRODUCCION") {
    return { status: 400, body: { error: "Confirmación inválida." } };
  }

  const states: any[] = [];
  for (const item of REPOSITORIES) {
    const [mainSha, targetSha] = await Promise.all([getBranchSha(item.repo, "main"), getBranchSha(item.repo, backupBranch)]);
    if (!mainSha || !targetSha) return { status: 409, body: { error: `No se encontró el respaldo completo para ${item.label}.`, repository: item.repo } };
    states.push({ ...item, main_sha: mainSha, target_sha: targetSha });
  }

  const safetyBranch = rollbackSafetyBranch();
  for (const item of states) await createBackup(item.repo, item.main_sha, safetyBranch);

  const restored: any[] = [];
  try {
    for (const item of states) {
      await updateMain(item.repo, item.target_sha, true);
      restored.push({ repo: item.repo, from: item.main_sha, to: item.target_sha });
    }
  } catch (restoreError) {
    const recovery: any[] = [];
    for (const item of restored.slice().reverse()) {
      try { await updateMain(item.repo, item.from, true); recovery.push({ repo: item.repo, ok: true }); }
      catch (recoveryError) { recovery.push({ repo: item.repo, ok: false, error: recoveryError instanceof Error ? recoveryError.message : "No se pudo recuperar main." }); }
    }
    return { status: 500, body: { error: "La restauración falló y se intentó recuperar el estado anterior.", recovery, safety_branch: safetyBranch } };
  }

  return { status: 200, body: { ok: true, restored: true, restored_by: admin.email, source_backup: backupBranch, safety_branch: safetyBranch, repositories: restored, untouched_staging: true, message: "Producción fue restaurada al respaldo seleccionado. Las ramas staging no se modificaron." } };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return response(405, { error: "Método no permitido." });

  try {
    const admin = await requireSuperAdmin(req);
    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "status");

    if (action === "status") return response(200, await handleStatus());
    if (action === "dry-run") return response(200, await handleDryRun());
    if (action === "history") return response(200, { ok: true, configuration: configuration(), backups: await listReleaseBackups(10) });
    if (action === "emergency-status") return response(200, await handleEmergencyStatus());
    if (action === "retry-quality") return response(200, await handleRetryQuality(body));
    if (action === "republish-tests") return response(200, await handleRepublishTests(body));
    if (action === "restore-stable-tests") {
      const result = await handleRestoreStableTests(body, admin);
      return response(result.status, result.body);
    }
    if (action === "release") {
      const result = await handleRelease(body, admin);
      return response(result.status, result.body);
    }
    if (action === "rollback") {
      const result = await handleRollback(body, admin);
      return response(result.status, result.body);
    }
    return response(400, { error: "Acción no reconocida." });
  } catch (error) {
    const status = Number((error as any)?.status || 500);
    return response(status, { error: error instanceof Error ? error.message : "No se pudo procesar el Centro de lanzamientos." });
  }
});
