import { describe, expect, it } from 'vitest';
import { polygonsOverlap } from '../src/io/geo';

describe('polygonsOverlap', () => {
  it('does not mistake a concave polygon centroid in a separate gap for overlap', () => {
    const concaveLane = [
      { lat: 0, lng: 0 },
      { lat: 0, lng: 4 },
      { lat: 1, lng: 4 },
      { lat: 1, lng: 1 },
      { lat: 3, lng: 1 },
      { lat: 3, lng: 4 },
      { lat: 4, lng: 4 },
      { lat: 4, lng: 0 },
    ];
    const separateGap = [
      { lat: 1.5, lng: 2 },
      { lat: 1.5, lng: 2.5 },
      { lat: 2.5, lng: 2.5 },
      { lat: 2.5, lng: 2 },
    ];

    expect(polygonsOverlap(concaveLane, separateGap)).toBe(false);
  });

  it('detects identical polygons whose vertices only touch the boundary', () => {
    const polygon = [
      { lat: 36.07, lng: 140.20 },
      { lat: 36.08, lng: 140.20 },
      { lat: 36.08, lng: 140.21 },
      { lat: 36.07, lng: 140.21 },
    ];

    expect(polygonsOverlap(polygon, [...polygon])).toBe(true);
  });
});
