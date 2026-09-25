const REPOSITORIES = [
  { key: 'admin', label: 'Admin', repo: 'jorge2610g/yummy-admin' },
  { key: 'restaurante', label: 'Restaurante', repo: 'jorge2610g/yummy-restaurante' },
  { key: 'retail', label: 'Retail', repo: 'jorge2610g/yummy-retail' },
  { key: 'profesionales', label: 'Profesionales', repo: 'jorge2610g/yummy-profesionales' },
  { key: 'streaming', label: 'Streaming', repo: 'jorge2610g/yummy-streaming' },
  { key: 'cliente', label: 'Cliente', repo: 'jorge2610g/mipagina' },
];

const GH_API = 'https://api.github.com';

function sendJson(res, status, body) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(body));
}

function env(name) {
  return String(process.env[name] || '').trim();
}

function githubHeaders({ write = false } = {}) {
  const token = env('YUMMY_RELEASE_GITHUB_TOKEN');
  const headers = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'YummyPro-Release-Center',
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (write) headers['Content-Type'] = 'application/json';
  return headers;
}

async function githubRequest(path, options = {}) {
  const response = await fetch(`${GH_API}${path}`, {
    ...options,
    headers: {
      ...githubHeaders({ write: !!options.body }),
      ...(options.headers || {}),
    },
  });
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (_) { data = { message: text || 'Respuesta inválida de GitHub' }; }
  if (!response.ok) {
    const error = new Error(data?.message || `GitHub respondió ${response.status}`);
    error.status = response.status;
    error.data = data;
    throw error;
  }
  return data;
}

async function getRef(repo, branch) {
  const data = await githubRequest(`/repos/${repo}/git/ref/heads/${encodeURIComponent(branch)}`);
  return data?.object?.sha || null;
}

async function compareBranches(repo) {
  return githubRequest(`/repos/${repo}/compare/main...staging`);
}

async function inspectRepository(item) {
  const [mainSha, stagingSha, comparison] = await Promise.all([
    getRef(item.repo, 'main'),
    getRef(item.repo, 'staging'),
    compareBranches(item.repo),
  ]);
  const status = String(comparison?.status || 'unknown');
  const aheadBy = Number(comparison?.ahead_by || 0);
  const behindBy = Number(comparison?.behind_by || 0);
  const safe = status === 'identical' || (status === 'ahead' && behindBy === 0);
  return {
    ...item,
    main_sha: mainSha,
    staging_sha: stagingSha,
    status,
    ahead_by: aheadBy,
    behind_by: behindBy,
    changed_files: Array.isArray(comparison?.files) ? comparison.files.length : 0,
    safe,
    needs_release: status === 'ahead' && aheadBy > 0,
  };
}

async function inspectAllRepositories() {
  const results = [];
  for (const item of REPOSITORIES) {
    try {
      results.push(await inspectRepository(item));
    } catch (error) {
      results.push({
        ...item,
        safe: false,
        needs_release: false,
        error: error.message || 'No se pudo inspeccionar el repositorio',
      });
    }
  }
  return results;
}

async function requireSuperAdmin(req) {
  const authorization = String(req.headers.authorization || '');
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    const error = new Error('Sesión de administrador requerida.');
    error.status = 401;
    throw error;
  }

  const supabaseUrl = env('SUPABASE_URL');
  const supabaseKey = env('SUPABASE_ANON_KEY') || env('SUPABASE_PUBLISHABLE_KEY');
  if (!supabaseUrl || !supabaseKey) {
    const error = new Error('El backend de releases todavía no tiene configurado el entorno de Supabase.');
    error.status = 503;
    throw error;
  }

  const accessToken = match[1];
  const authHeaders = {
    apikey: supabaseKey,
    Authorization: `Bearer ${accessToken}`,
  };
  const userResponse = await fetch(`${supabaseUrl.replace(/\/$/, '')}/auth/v1/user`, { headers: authHeaders });
  if (!userResponse.ok) {
    const error = new Error('La sesión del administrador no es válida o expiró.');
    error.status = 401;
    throw error;
  }
  const user = await userResponse.json();
  if (!user?.id) {
    const error = new Error('No se pudo identificar al administrador.');
    error.status = 401;
    throw error;
  }

  const adminResponse = await fetch(
    `${supabaseUrl.replace(/\/$/, '')}/rest/v1/admin_users?user_id=eq.${encodeURIComponent(user.id)}&select=user_id&limit=1`,
    { headers: authHeaders }
  );
  if (!adminResponse.ok) {
    const error = new Error('No se pudo verificar el permiso de administrador global.');
    error.status = 403;
    throw error;
  }
  const rows = await adminResponse.json();
  if (!Array.isArray(rows) || !rows.length) {
    const error = new Error('Solo el administrador global puede lanzar versiones a Producción.');
    error.status = 403;
    throw error;
  }
  return { id: user.id, email: user.email || null };
}

function releaseConfiguration() {
  return {
    github_token_configured: !!env('YUMMY_RELEASE_GITHUB_TOKEN'),
    release_enabled: env('YUMMY_RELEASE_ENABLED').toLowerCase() === 'true',
  };
}

function backupRefName(timestamp = new Date()) {
  return `backup/release-${timestamp.toISOString().replace(/[:.]/g, '-').replace('T', '-').replace('Z', '')}`;
}

async function createBackup(repo, sha, branchName) {
  return githubRequest(`/repos/${repo}/git/refs`, {
    method: 'POST',
    body: JSON.stringify({ ref: `refs/heads/${branchName}`, sha }),
  });
}

async function updateMain(repo, sha, force = false) {
  return githubRequest(`/repos/${repo}/git/refs/heads/main`, {
    method: 'PATCH',
    body: JSON.stringify({ sha, force }),
  });
}

module.exports = {
  REPOSITORIES,
  sendJson,
  inspectAllRepositories,
  requireSuperAdmin,
  releaseConfiguration,
  backupRefName,
  createBackup,
  updateMain,
};
