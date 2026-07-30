import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { writeChangeset } from '../server/changeset';
import { defaultProject, newMapObject } from '../src/model/factories';

const temporaryRoots: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryRoots.splice(0).map((path) => rm(path, {
    recursive: true,
    force: true,
  })));
});

describe('changeset output', () => {
  it('検証エラーがあっても座標と検証結果を未完成パッケージへ出力する', async () => {
    const root = await mkdtemp(join(tmpdir(), 'obstacle-plotter-'));
    temporaryRoots.push(root);
    const repoRoot = join(root, 'repo');
    await mkdir(repoRoot);

    const project = defaultProject();
    const first = newMapObject('ashoreArea');
    const second = newMapObject('navigableWater');
    second.exportId = first.exportId;
    project.objects = [first, second];

    const relativePath = await writeChangeset(repoRoot, project);
    expect(relativePath).toContain('-INCOMPLETE');
    const target = resolve(repoRoot, relativePath);
    const packageJson = JSON.parse(
      await readFile(join(target, 'changeset.json'), 'utf8'),
    ) as { validation: Array<{ code: string; level: string }> };

    expect(packageJson.validation).toContainEqual(expect.objectContaining({
      code: 'object.id.duplicate',
      level: 'error',
    }));
    expect(await readFile(join(target, 'files', 'sakuragawa_obstacles.json'), 'utf8'))
      .toContain(first.exportId);
    expect(await readFile(join(target, 'CHANGESET.md'), 'utf8'))
      .toContain('未完成データ');
  });
});
