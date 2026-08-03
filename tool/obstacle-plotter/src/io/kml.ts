import type { Folder, MapObject, Project } from '../model/types';

const escape = (value: string) => value.replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[character]!);
const coordinates = (points: { lat: number; lng: number }[], closed = false) => {
  const values = closed && points.length > 0 ? [...points, points[0]] : points;
  return values.map((point) => `${point.lng},${point.lat},0`).join(' ');
};
function placemark(object: MapObject): string {
  const geometry = object.geometry;
  const extended = `<ExtendedData><Data name="exportId"><value>${escape(object.exportId)}</value></Data><Data name="kind"><value>${escape(object.kind)}</value></Data><Data name="verificationStatus"><value>${escape(object.verificationStatus)}</value></Data>${object.bridgeId ? `<Data name="bridgeId"><value>${escape(object.bridgeId)}</value></Data>` : ''}${object.centerlineId ? `<Data name="centerlineId"><value>${escape(object.centerlineId)}</value></Data>` : ''}${object.laneDirection ? `<Data name="direction"><value>${escape(object.laneDirection)}</value></Data>` : ''}${object.laneLeg ? `<Data name="leg"><value>${escape(object.laneLeg)}</value></Data>` : ''}${geometry.type === 'baseline' ? `<Data name="closed"><value>${geometry.closed}</value></Data>` : ''}</ExtendedData>`;
  const body = geometry.type === 'point'
    ? `<Point><coordinates>${coordinates([geometry.point])}</coordinates></Point>`
    : geometry.type === 'polygon'
      ? `<Polygon><outerBoundaryIs><LinearRing><coordinates>${coordinates(geometry.points, true)}</coordinates></LinearRing></outerBoundaryIs></Polygon>`
      : `<LineString><coordinates>${coordinates(geometry.points)}</coordinates></LineString>`;
  return `<Placemark><name>${escape(object.name)}</name><description>${escape(object.description)}</description>${extended}${body}</Placemark>`;
}
function folderXml(folder: Folder, folders: Folder[], objects: MapObject[]): string {
  const children = folders.filter((child) => child.parentFolderId === folder.id).sort((a, b) => a.order - b.order).map((child) => folderXml(child, folders, objects)).join('');
  const own = objects.filter((object) => object.parentFolderId === folder.id).sort((a, b) => a.order - b.order).map(placemark).join('');
  return `<Folder><name>${escape(folder.name)}</name>${own}${children}</Folder>`;
}
export function exportKml(project: Project): string {
  const roots = project.folders.filter((folder) => folder.parentFolderId === null).sort((a, b) => a.order - b.order).map((folder) => folderXml(folder, project.folders, project.objects)).join('');
  const unfoldered = project.objects.filter((object) => object.parentFolderId === null).map(placemark).join('');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>${escape(project.name)}</name>${roots}${unfoldered}</Document></kml>\n`;
}
