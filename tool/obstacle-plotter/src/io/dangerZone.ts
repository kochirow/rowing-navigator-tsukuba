import { bearing, destination } from './geo';
import type { Coordinate } from '../model/types';

export type DangerZonePreview = {
  waterSide: Coordinate[];
  landSide: Coordinate[];
  full: Coordinate[];
};

/** Dart の LegacyDangerZoneGenerator.createDangerRectangle と同じ測地線計算。 */
export function createDangerRectangle(
  start: Coordinate,
  end: Coordinate,
  waterSideMeters: number,
  landSideMeters: number,
): DangerZonePreview | null {
  if (start.lat === end.lat && start.lng === end.lng) return null;
  const direction = bearing(start, end);
  const waterBearing = direction - 90;
  const landBearing = direction + 90;
  const startWater = destination(start, waterBearing, waterSideMeters);
  const endWater = destination(end, waterBearing, waterSideMeters);
  const endLand = destination(end, landBearing, landSideMeters);
  const startLand = destination(start, landBearing, landSideMeters);
  return {
    waterSide: [start, end, endWater, startWater],
    landSide: [start, end, endLand, startLand],
    full: [startWater, endWater, endLand, startLand],
  };
}

export function dangerZonePreviews(
  points: Coordinate[],
  waterSideMeters: number,
  landSideMeters: number,
  closed: boolean,
): DangerZonePreview[] {
  const segments = closed ? points.length : points.length - 1;
  const previews: DangerZonePreview[] = [];
  for (let index = 0; index < segments; index += 1) {
    const preview = createDangerRectangle(points[index], points[(index + 1) % points.length], waterSideMeters, landSideMeters);
    if (preview) previews.push(preview);
  }
  return previews;
}
