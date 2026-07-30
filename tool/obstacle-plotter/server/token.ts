import { readFile } from 'node:fs/promises';
import jwt from 'jsonwebtoken';

export type TokenConfig = {
  teamId: string;
  keyId: string;
  mapsId: string;
  privateKeyPath: string;
  origin: string;
  ttlSeconds: number;
};

export async function createMapKitToken(config: TokenConfig): Promise<string> {
  const privateKey = await readFile(config.privateKeyPath, 'utf8');
  const issuedAt = Math.floor(Date.now() / 1000);
  return jwt.sign({
    iss: config.teamId,
    iat: issuedAt,
    exp: issuedAt + config.ttlSeconds,
    scope: 'mapkit_js',
    origin: config.origin,
  }, privateKey, { algorithm: 'ES256', keyid: config.keyId, header: { alg: 'ES256', typ: 'JWT' } });
}
