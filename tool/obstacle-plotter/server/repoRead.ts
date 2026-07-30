import { readFile, realpath } from 'node:fs/promises';
import { resolve } from 'node:path';

export const profileRelativePath = 'assets/data/sakuragawa_obstacles.json';

export async function readBundledProfile(repoRoot: string): Promise<string> {
  return readFile(resolve(repoRoot, profileRelativePath), 'utf8');
}

/** Dartの公開済みWeb FirebaseOptionsだけを取り出す。秘密情報は扱わない。 */
export async function readFirebaseWebConfig(repoRoot: string): Promise<Record<string, string>> {
  const source = await readFile(resolve(repoRoot, 'lib/firebase_options.dart'), 'utf8');
  const web = /static const FirebaseOptions web = FirebaseOptions\(([\s\S]*?)\n\s*\);/.exec(source)?.[1];
  if (!web) throw new Error('lib/firebase_options.dart からweb設定を読み取れません。');
  const aliases: Record<string, string> = {
    apiKey: 'apiKey', appId: 'appId', messagingSenderId: 'messagingSenderId', projectId: 'projectId',
    authDomain: 'authDomain', storageBucket: 'storageBucket', measurementId: 'measurementId', databaseURL: 'databaseURL',
  };
  const config: Record<string, string> = {};
  for (const [dartKey, jsKey] of Object.entries(aliases)) {
    const value = new RegExp(`${dartKey}:\\s*'([^']+)'`).exec(web)?.[1];
    if (value) config[jsKey] = value;
  }
  if (!config.apiKey || !config.appId || !config.projectId) throw new Error('Firebase web設定が不完全です。');
  return config;
}

/** PROFILE_WRITE_PATH 以外を読む・書くためのパス解決を提供しない。 */
export async function assertExactProfileWritePath(repoRoot: string, configuredPath: string): Promise<string> {
  const expected = resolve(repoRoot, profileRelativePath);
  const requested = resolve(configuredPath);
  if (requested !== expected) throw new Error('PROFILE_WRITE_PATH は同梱プロファイルの完全一致パスだけを指定できます。');
  return realpath(repoRoot).then(() => requested);
}
