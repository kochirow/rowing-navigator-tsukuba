import { describe, expect, it } from 'vitest';
import { createDangerRectangle, dangerZonePreviews } from '../src/io/dangerZone';
import { distanceMeters } from '../src/io/geo';

describe('danger-zone preview', () => {
  it('creates an asymmetric shore rectangle with the requested metrical sides', () => {
    const preview = createDangerRectangle({ lat: 36.07, lng: 140.19 }, { lat: 36.07, lng: 140.191 }, 5, 15)!;
    expect(distanceMeters(preview.full[0], { lat: 36.07, lng: 140.19 })).toBeCloseTo(5, 3);
    expect(distanceMeters(preview.full[3], { lat: 36.07, lng: 140.19 })).toBeCloseTo(15, 3);
  });
  it('includes the closing segment exactly once for closed baselines', () => {
    const points = [{ lat: 36.07, lng: 140.19 }, { lat: 36.071, lng: 140.19 }, { lat: 36.071, lng: 140.191 }];
    expect(dangerZonePreviews(points, 5, 5, false)).toHaveLength(2);
    expect(dangerZonePreviews(points, 5, 5, true)).toHaveLength(3);
  });
});
