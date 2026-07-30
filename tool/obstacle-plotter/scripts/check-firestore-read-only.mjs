import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../src/io/firestore.ts', import.meta.url), 'utf8');
const forbidden = ['setDoc', 'updateDoc', 'deleteDoc', 'addDoc'];
const found = forbidden.filter((name) => new RegExp(`\\b${name}\\b`).test(source));
if (found.length) throw new Error(`Firestore書き込みAPIは禁止です: ${found.join(', ')}`);
if (!source.includes('writeBatch') || !source.includes("'teams', teamId, 'members'")) {
  throw new Error('招待コードによるツール用読み取り所属の最小限のatomic writeがありません。');
}
console.log('Firestore safety data is read-only; only tool membership may be created atomically.');
