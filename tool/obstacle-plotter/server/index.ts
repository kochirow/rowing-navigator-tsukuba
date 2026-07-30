import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createMapKitToken, type TokenConfig } from './token';
import { writeChangeset } from './changeset';
import { readBundledProfile, readFirebaseWebConfig } from './repoRead';
import type { Project } from '../src/model/types';

const toolRoot = process.cwd();
const repoRoot = resolve(toolRoot, '../..');

function envFile(): Promise<Record<string, string>> {
  return readFile(resolve(toolRoot, '.env'), 'utf8').then((contents) => Object.fromEntries(contents.split(/\r?\n/).flatMap((line) => {
    const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    return match && !match[1].startsWith('#') ? [[match[1], match[2]]] : [];
  }))).catch(() => ({}));
}
function json(response: ServerResponse, status: number, value: unknown) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  response.end(JSON.stringify(value));
}
async function body(request: IncomingMessage): Promise<string> {
  let value = '';
  for await (const chunk of request) { value += chunk; if (value.length > 10_000_000) throw new Error('リクエストが大きすぎます。'); }
  return value;
}
async function config(): Promise<TokenConfig> {
  const values = { ...await envFile(), ...Object.fromEntries(Object.entries(process.env).filter(([, value]) => value !== undefined)) } as Record<string, string>;
  const missing = ['APPLE_TEAM_ID', 'APPLE_KEY_ID', 'APPLE_MAPS_ID', 'APPLE_PRIVATE_KEY_PATH'].filter((name) => !values[name]);
  if (missing.length) throw new Error(`.env の必須項目が不足しています: ${missing.join(', ')}。.env.example をコピーして設定してください。`);
  return { teamId: values.APPLE_TEAM_ID, keyId: values.APPLE_KEY_ID, mapsId: values.APPLE_MAPS_ID, privateKeyPath: values.APPLE_PRIVATE_KEY_PATH, origin: values.MAPKIT_ORIGIN || 'http://127.0.0.1:5173', ttlSeconds: Number(values.TOKEN_TTL_SECONDS || '1800') };
}

const port = Number((await envFile()).PORT || process.env.PORT || '5174');
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? '/', 'http://127.0.0.1');
    // 変更適用パッケージやJSON読込みはMapKitの鍵を必要としない。以前は
    // MapKit設定が無いだけでAPI全体を起動しなかったため、これらの作業まで
    // できなくなっていた。地図表示が必要になるリクエスト時だけ設定を検証する。
    if (request.method === 'GET' && url.pathname === '/api/health') return json(response, 200, { status: 'ok', changeset: 'available' });
    if (request.method === 'GET' && url.pathname === '/api/mapkit/token') return json(response, 200, { token: await createMapKitToken(await config()) });
    if (request.method === 'GET' && url.pathname === '/api/profile') {
      const profile = await readBundledProfile(repoRoot);
      response.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
      return response.end(profile);
    }
    if (request.method === 'GET' && url.pathname === '/api/firebase-config') return json(response, 200, await readFirebaseWebConfig(repoRoot));
    if (request.method === 'POST' && url.pathname === '/api/changeset') {
      const project = JSON.parse(await body(request)) as Project;
      return json(response, 201, { path: await writeChangeset(repoRoot, project) });
    }
    return json(response, 404, { message: 'Not found' });
  } catch (error) { return json(response, 400, { message: error instanceof Error ? error.message : '処理に失敗しました。' }); }
});
server.listen(port, '127.0.0.1', () => console.log(`Obstacle plotter API: http://127.0.0.1:${port}`));
