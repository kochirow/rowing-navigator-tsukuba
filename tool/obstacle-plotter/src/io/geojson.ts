import type { Coordinate, MapObject, Project } from '../model/types';

const ring = (points: Coordinate[]) => [...points, points[0]].map((point) => [point.lng, point.lat]);
const properties = (object: MapObject) => ({
  exportId: object.exportId,
  name: object.name,
  kind: object.kind,
  verificationStatus: object.verificationStatus,
  description: object.description,
  ...(object.bridgeId ? { bridgeId: object.bridgeId } : {}),
  ...(object.centerlineId ? { centerlineId: object.centerlineId } : {}),
  ...(object.laneDirection ? { direction: object.laneDirection } : {}),
  ...(object.laneLeg ? { leg: object.laneLeg } : {}),
  ...(object.geometry.type === 'baseline' ? { rowingNavigatorGeometry: 'baseline', closed: object.geometry.closed } : {}),
});

export function exportGeoJson(project: Project): string {
  const features: Array<Record<string, unknown>> = [];
  for (const object of project.objects) {
    if (object.geometry.type === 'point') {
      features.push({ type: 'Feature', properties: properties(object), geometry: { type: 'Point', coordinates: [object.geometry.point.lng, object.geometry.point.lat] } });
    } else if (object.geometry.type === 'polyline' || object.geometry.type === 'baseline') {
      features.push({ type: 'Feature', properties: properties(object), geometry: { type: 'LineString', coordinates: object.geometry.points.map((point) => [point.lng, point.lat]) } });
    } else {
      features.push({ type: 'Feature', properties: properties(object), geometry: { type: 'Polygon', coordinates: [ring(object.geometry.points)] } });
    }
  }
  return `${JSON.stringify({ type: 'FeatureCollection', features }, null, 2)}\n`;
}
