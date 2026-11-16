import { createServer } from 'node:http';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { openStore } from './db.mjs';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const ROOT = resolve(__dirname, '..');
const DIST = join(ROOT, 'dist');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8',
};

function readBody(req) {
  return new Promise((resolvePromise, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 2 * 1024 * 1024) {
        reject(Object.assign(new Error('请求内容过大'), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (!chunks.length) return resolvePromise({});
      try {
        resolvePromise(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(Object.assign(new Error('请求内容不是合法 JSON'), { status: 400 }));
      }
    });
    req.on('error', reject);
  });
}

function json(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  });
  res.end(body);
}

function createRouter() {
  const routes = [];
  const add = (method, pattern, handler) => {
    const keys = [];
    const regex = new RegExp(
      `^${pattern.replace(/:([A-Za-z]+)/g, (_, key) => {
        keys.push(key);
        return '([^/]+)';
      })}$`,
    );
    routes.push({ method, regex, keys, handler });
  };
  return {
    get: (p, h) => add('GET', p, h),
    post: (p, h) => add('POST', p, h),
    patch: (p, h) => add('PATCH', p, h),
    delete: (p, h) => add('DELETE', p, h),
    match(method, pathname) {
      for (const route of routes) {
        if (route.method !== method) continue;
        const m = route.regex.exec(pathname);
        if (!m) continue;
        const params = {};
        route.keys.forEach((key, i) => { params[key] = decodeURIComponent(m[i + 1]); });
        return { handler: route.handler, params };
      }
      return null;
    },
  };
}

function serveStatic(req, res, pathname) {
  let target = normalize(join(DIST, pathname));
  if (!target.startsWith(DIST + sep) && target !== DIST) {
    res.writeHead(403).end('Forbidden');
    return;
  }
  if (!existsSync(DIST)) {
    json(res, 503, { error: '尚未构建前端资源，请先运行 npm run build' });
    return;
  }
  if (!existsSync(target) || !statSync(target).isFile()) {
    target = join(DIST, 'index.html');
    if (!existsSync(target)) {
      json(res, 404, { error: '资源不存在' });
      return;
    }
  }
  const type = MIME[extname(target).toLowerCase()] ?? 'application/octet-stream';
  const isAsset = target.includes(`${sep}assets${sep}`);
  res.writeHead(200, {
    'content-type': type,
    'cache-control': isAsset ? 'public, max-age=31536000, immutable' : 'no-cache',
  });
  createReadStream(target).pipe(res);
}

export function createApp({ dbFile = 'data/timeflow.db' } = {}) {
  const store = openStore(dbFile);
  const router = createRouter();

  router.get('/api/health', () => ({ ok: true, uptime: process.uptime() }));
  router.get('/api/state', () => store.snapshot());

  router.get('/api/projects', () => store.listProjects());
  router.post('/api/projects', ({ body }) => store.createProject(body));
  router.patch('/api/projects/:id', ({ params, body }) => store.updateProject(params.id, body));
  router.delete('/api/projects/:id', ({ params }) => store.deleteProject(params.id));

  router.get('/api/tasks', () => store.listTasks());
  router.post('/api/tasks', ({ body }) => store.createTask(body));
  router.post('/api/tasks/reorder', ({ body }) => store.reorderTasks(body.ids));
  router.patch('/api/tasks/:id', ({ params, body }) => store.updateTask(params.id, body));
  router.delete('/api/tasks/:id', ({ params }) => store.deleteTask(params.id));

  router.post('/api/tasks/:id/subtasks', ({ params, body }) => store.createSubtask(params.id, body));
  router.patch('/api/subtasks/:id', ({ params, body }) => store.updateSubtask(params.id, body));
  router.delete('/api/subtasks/:id', ({ params }) => store.deleteSubtask(params.id));

  router.get('/api/entries', () => store.listEntries());
  router.post('/api/entries', ({ body }) => store.createEntry(body));
  router.patch('/api/entries/:id', ({ params, body }) => store.updateEntry(params.id, body));
  router.delete('/api/entries/:id', ({ params }) => store.deleteEntry(params.id));

  router.post('/api/timer/start', ({ body }) => store.startTimer(body.taskId, body.at));
  router.post('/api/timer/stop', ({ body }) => store.stopTimer(body.at) ?? { stopped: false });

  router.patch('/api/settings', ({ body }) => store.updateSettings(body));

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const { pathname } = url;
    try {
      if (pathname === '/api' || pathname.startsWith('/api/')) {
        const match = router.match(req.method, pathname);
        if (!match) {
          json(res, 404, { error: `未知接口 ${req.method} ${pathname}` });
          return;
        }
        const body = ['POST', 'PATCH', 'PUT'].includes(req.method) ? await readBody(req) : {};
        const result = await match.handler({ params: match.params, body, query: url.searchParams, req });
        if (res.writableEnded) return;
        json(res, 200, result ?? { ok: true });
        return;
      }
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        json(res, 405, { error: '不支持的方法' });
        return;
      }
      serveStatic(req, res, pathname);
    } catch (error) {
      const status = error.status ?? 500;
      if (status >= 500) console.error('[api]', error);
      if (!res.writableEnded) {
        json(res, status, { error: error.message || '服务器内部错误' });
      }
    }
  });

  return { server, store };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const port = Number(process.env.PORT || 8787);
  const dbFile = process.env.DB_FILE || join(ROOT, 'data', 'timeflow.db');
  const { server, store } = createApp({ dbFile });
  server.listen(port, '127.0.0.1', () => {
    console.log(`\n  时序 TimeFlow 已启动 → http://127.0.0.1:${port}\n  数据文件: ${dbFile}\n`);
  });
  const shutdown = () => {
    server.close(() => { store.close(); process.exit(0); });
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
