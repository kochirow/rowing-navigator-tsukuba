import type { Coordinate } from '../model/types';

export const earthRadiusMeters = 6371000;
const radians = (degrees: number) => degrees * Math.PI / 180;
const degrees = (radiansValue: number) => radiansValue * 180 / Math.PI;

export function sameCoordinate(a: Coordinate, b: Coordinate): boolean {
  return a.lat === b.lat && a.lng === b.lng;
}

export function roundCoordinate(point: Coordinate): Coordinate {
  return { lat: Number(point.lat.toFixed(7)), lng: Number(point.lng.toFixed(7)) };
}

export function bearing(from: Coordinate, to: Coordinate): number {
  const lat1 = radians(from.lat);
  const lat2 = radians(to.lat);
  const deltaLng = radians(to.lng - from.lng);
  const y = Math.sin(deltaLng) * Math.cos(lat2);
  const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(deltaLng);
  return (degrees(Math.atan2(y, x)) + 360) % 360;
}

export function destination(start: Coordinate, bearingDegrees: number, distanceMeters: number): Coordinate {
  const angularDistance = distanceMeters / earthRadiusMeters;
  const heading = radians(bearingDegrees);
  const latitude = radians(start.lat);
  const longitude = radians(start.lng);
  const destinationLatitude = Math.asin(
    Math.sin(latitude) * Math.cos(angularDistance) + Math.cos(latitude) * Math.sin(angularDistance) * Math.cos(heading),
  );
  const destinationLongitude = longitude + Math.atan2(
    Math.sin(heading) * Math.sin(angularDistance) * Math.cos(latitude),
    Math.cos(angularDistance) - Math.sin(latitude) * Math.sin(destinationLatitude),
  );
  return { lat: degrees(destinationLatitude), lng: ((degrees(destinationLongitude) + 540) % 360) - 180 };
}

export function distanceMeters(a: Coordinate, b: Coordinate): number {
  const deltaLat = radians(b.lat - a.lat);
  const deltaLng = radians(b.lng - a.lng);
  const lat1 = radians(a.lat);
  const lat2 = radians(b.lat);
  const sinLat = Math.sin(deltaLat / 2);
  const sinLng = Math.sin(deltaLng / 2);
  const haversine = sinLat * sinLat + Math.cos(lat1) * Math.cos(lat2) * sinLng * sinLng;
  return 2 * earthRadiusMeters * Math.atan2(Math.sqrt(haversine), Math.sqrt(1 - haversine));
}

export function pointInPolygon(point: Coordinate, polygon: Coordinate[]): boolean {
  let inside = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const a = polygon[i];
    const b = polygon[j];
    const intersects = ((a.lat > point.lat) !== (b.lat > point.lat))
      && point.lng < (b.lng - a.lng) * (point.lat - a.lat) / (b.lat - a.lat) + a.lng;
    if (intersects) inside = !inside;
  }
  return inside;
}

function ccw(a: Coordinate, b: Coordinate, c: Coordinate): number {
  return (b.lng - a.lng) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lng - a.lng);
}

export function segmentsIntersect(a: Coordinate, b: Coordinate, c: Coordinate, d: Coordinate): boolean {
  const abC = ccw(a, b, c);
  const abD = ccw(a, b, d);
  const cdA = ccw(c, d, a);
  const cdB = ccw(c, d, b);
  return abC * abD < 0 && cdA * cdB < 0;
}

export function hasSelfIntersection(points: Coordinate[]): boolean {
  if (points.length < 4) return false;
  for (let first = 0; first < points.length; first += 1) {
    const nextFirst = (first + 1) % points.length;
    for (let second = first + 1; second < points.length; second += 1) {
      const nextSecond = (second + 1) % points.length;
      if (first === second || nextFirst === second || nextSecond === first) continue;
      if (segmentsIntersect(points[first], points[nextFirst], points[second], points[nextSecond])) return true;
    }
  }
  return false;
}

/// 面積を持つポリゴンの重なりだけを検出する。
///
/// 辺や頂点が接するだけのレーンは許容する。中心線の隙間を閉じないまま
/// 作図できるようにし、実行時のレーン解決でも境界は非内包として扱う。
export function polygonsOverlap(first: Coordinate[], second: Coordinate[]): boolean {
  if (first.length < 3 || second.length < 3) return false;
  for (const point of first) if (pointInPolygon(point, second)) return true;
  for (const point of second) if (pointInPolygon(point, first)) return true;
  for (let firstIndex = 0; firstIndex < first.length; firstIndex += 1) {
    const firstNext = (firstIndex + 1) % first.length;
    for (let secondIndex = 0; secondIndex < second.length; secondIndex += 1) {
      const secondNext = (secondIndex + 1) % second.length;
      if (segmentsIntersect(first[firstIndex], first[firstNext], second[secondIndex], second[secondNext])) return true;
    }
  }
  const firstCenter = first.reduce((total, point) => ({ lat: total.lat + point.lat / first.length, lng: total.lng + point.lng / first.length }), { lat: 0, lng: 0 });
  const secondCenter = second.reduce((total, point) => ({ lat: total.lat + point.lat / second.length, lng: total.lng + point.lng / second.length }), { lat: 0, lng: 0 });
  return pointInPolygon(firstCenter, second) || pointInPolygon(secondCenter, first);
}

/// 点から地理座標の線分までの近似距離 [m]。桜川の作図範囲では局所平面近似で
/// 十分であり、レーン間の意図しない大きな隙間を検出するためだけに使う。
export function distancePointToSegmentMeters(point: Coordinate, start: Coordinate, end: Coordinate): number {
  const latitudeRadians = radians(point.lat);
  const toLocal = (value: Coordinate) => ({
    east: radians(value.lng - point.lng) * earthRadiusMeters * Math.cos(latitudeRadians),
    north: radians(value.lat - point.lat) * earthRadiusMeters,
  });
  const a = toLocal(start);
  const b = toLocal(end);
  const deltaEast = b.east - a.east;
  const deltaNorth = b.north - a.north;
  const lengthSquared = deltaEast * deltaEast + deltaNorth * deltaNorth;
  if (lengthSquared <= 1e-9) return Math.hypot(a.east, a.north);
  const ratio = Math.max(0, Math.min(1, -(a.east * deltaEast + a.north * deltaNorth) / lengthSquared));
  return Math.hypot(a.east + deltaEast * ratio, a.north + deltaNorth * ratio);
}
