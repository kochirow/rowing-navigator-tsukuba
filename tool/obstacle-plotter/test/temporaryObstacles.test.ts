import { describe, expect, it } from 'vitest';
import { promoteTemporaryObject, temporaryObstacleObjects } from '../src/io/temporaryObstacles';

const point = (latitude: number, longitude: number) => ({ latitude, longitude });

describe('temporary obstacle import', () => {
  it('imports a Firestore temporary obstacle as an unpromoted candidate', () => {
    const result = temporaryObstacleObjects([{
      id: 'AbC123', name: '新規流木', kind: 'generic',
      points: [point(36.07, 140.19), point(36.071, 140.19), point(36.071, 140.191)],
      createdAt: { toDate: () => new Date('2026-07-29T00:00:00Z') },
    }]);
    expect(result.skipped).toEqual([]);
    expect(result.objects).toHaveLength(1);
    expect(result.objects[0].origin).toMatchObject({ kind: 'temporary', docId: 'AbC123' });
    expect(result.objects[0].parentFolderId).toBe('fld_imported');
  });

  it('promotes a temporary polygon into a fixed driftwood baseline and records its source', () => {
    const temporary = temporaryObstacleObjects([{
      id: 'temporary1', name: '新規流木', points: [point(36.07, 140.19), point(36.071, 140.19), point(36.071, 140.191)],
    }]).objects[0];
    const promoted = promoteTemporaryObject(temporary, 'driftwood', 'driftwood_new');
    expect(promoted.origin).toEqual({ kind: 'drawn' });
    expect(promoted.promotedFromTemporaryDocId).toBe('temporary1');
    expect(promoted.geometry).toMatchObject({ type: 'baseline', closed: true });
    expect(promoted.verificationStatus).toBe('field_verified');
  });
});
