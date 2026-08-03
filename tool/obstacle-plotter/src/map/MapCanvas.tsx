import { useEffect, useRef, useState } from 'react';
import { dangerZonePreviews } from '../io/dangerZone';
import type { Coordinate, MapObject, Project } from '../model/types';
import { bearing, destination, distanceMeters, pointInPolygon } from '../io/geo';
import { colorWithAlpha, objectColor } from './objectColor';

export type MapInteractionMode = 'pan' | 'add' | 'move';
type Props = {
  project: Project;
  selected: MapObject | undefined;
  mode: MapInteractionMode;
  onAddPoint: (point: Coordinate) => void;
  onMovePoint: (index: number, point: Coordinate) => void;
  onFinishInteraction: () => void;
};
// Use the complete bundle. The modular `mapkit.core.js` bundle can report that
// `map` is loaded before annotation/overlay constructors are ready, which
// makes a later redraw fail when an object is selected.
const scriptUrl = 'https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.js';
// Survey-grade vertex editing needs to reach far closer than the default
// camera range. This is a camera distance in metres, not a screen zoom level.
const minimumEditCameraDistance = 8;
const maximumCameraDistance = 250_000;
const defaultMapCamera = { lat: 36.078294, lng: 140.195898, distance: 1500 };
const laneArrowSpacingMeters = 40;

type LaneArrow = { point: Coordinate; bearingDegrees: number };

function lineIntersection(firstStart: Coordinate, firstEnd: Coordinate, secondStart: Coordinate, secondEnd: Coordinate): Coordinate | null {
  const firstLng = firstEnd.lng - firstStart.lng;
  const firstLat = firstEnd.lat - firstStart.lat;
  const secondLng = secondEnd.lng - secondStart.lng;
  const secondLat = secondEnd.lat - secondStart.lat;
  const denominator = firstLng * secondLat - firstLat * secondLng;
  if (Math.abs(denominator) < 1e-14) return null;
  const offsetLng = secondStart.lng - firstStart.lng;
  const offsetLat = secondStart.lat - firstStart.lat;
  const firstRatio = (offsetLng * secondLat - offsetLat * secondLng) / denominator;
  const secondRatio = (offsetLng * firstLat - offsetLat * firstLng) / denominator;
  if (firstRatio < 0 || firstRatio > 1 || secondRatio < 0 || secondRatio > 1) return null;
  return {
    lat: firstStart.lat + firstLat * firstRatio,
    lng: firstStart.lng + firstLng * firstRatio,
  };
}

/// 中心線の接線に直交する断面とレーンの交点から、レーン内部の矢印位置を
/// 得る。中心線そのものは2枚のレーンの間にあるので、そこへ直接矢印を置くと
/// 何も表示されない。この断面法なら各帯の内部に置きながら接線方位を保てる。
function laneCrossSectionPoints(center: Coordinate, tangentBearing: number, polygon: Coordinate[]): Coordinate[] {
  const start = destination(center, tangentBearing - 90, 100);
  const end = destination(center, tangentBearing + 90, 100);
  const intersections: Coordinate[] = [];
  for (let index = 0; index < polygon.length; index += 1) {
    const point = lineIntersection(start, end, polygon[index], polygon[(index + 1) % polygon.length]);
    if (!point || intersections.some((existing) => Math.abs(existing.lat - point.lat) < 1e-9 && Math.abs(existing.lng - point.lng) < 1e-9)) continue;
    intersections.push(point);
  }
  intersections.sort((first, second) => distanceMeters(start, first) - distanceMeters(start, second));
  const inside = [] as Coordinate[];
  for (let index = 0; index < intersections.length - 1; index += 1) {
    const first = intersections[index];
    const second = intersections[index + 1];
    const midpoint = { lat: (first.lat + second.lat) / 2, lng: (first.lng + second.lng) / 2 };
    if (pointInPolygon(midpoint, polygon)) inside.push(midpoint);
  }
  return inside;
}

/// レーンポリゴンの頂点順ではなく、紐付いた航路中心線の接線から矢印を作る。
/// アプリの `along` / `against` と同じ基準なので、作図時に向きの反転を地図上で
/// 確認できる。
function laneArrows(project: Project): LaneArrow[] {
  const centerlines = new Map(project.objects
    .filter((object) => object.kind === 'channelCenterline' && object.geometry.type === 'polyline')
    .map((object) => [object.exportId, object]));
  const soleCenterline = centerlines.size === 1 ? [...centerlines.values()][0] : undefined;
  const lanes = project.objects.filter((object) => object.visible && object.kind === 'lane' && object.geometry.type === 'polygon' && object.laneDirection);
  if (!lanes.length) return [];
  const arrows: LaneArrow[] = [];
  for (const lane of lanes) {
    const centerline = (lane.centerlineId ? centerlines.get(lane.centerlineId) : undefined) ?? soleCenterline;
    if (!centerline || centerline.geometry.type !== 'polyline' || lane.geometry.type !== 'polygon') continue;
    const points = centerline.geometry.points;
    let nextArrowAt = laneArrowSpacingMeters / 2;
    for (let index = 0; index < points.length - 1; index += 1) {
      const start = points[index];
      const end = points[index + 1];
      const segmentLength = distanceMeters(start, end);
      if (segmentLength < 0.01) continue;
      const tangent = bearing(start, end);
      while (nextArrowAt <= segmentLength) {
        const ratio = nextArrowAt / segmentLength;
        const point = {
          lat: start.lat + (end.lat - start.lat) * ratio,
          lng: start.lng + (end.lng - start.lng) * ratio,
        };
        for (const arrowPoint of laneCrossSectionPoints(point, tangent, lane.geometry.points)) {
          arrows.push({
            point: arrowPoint,
            bearingDegrees: (tangent + (lane.laneDirection === 'against' ? 180 : 0)) % 360,
          });
        }
        nextArrowAt += laneArrowSpacingMeters;
      }
      nextArrowAt -= segmentLength;
    }
  }
  return arrows;
}

async function loadMapKit(): Promise<any> {
  if ((window as any).mapkit) return (window as any).mapkit;
  await new Promise<void>((resolve, reject) => {
    const script = document.createElement('script');
    script.src = scriptUrl;
    script.async = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error('MapKit JS を読み込めませんでした。'));
    document.head.append(script);
  });
  return (window as any).mapkit;
}

async function loadMapLibraries(mk: any, libraries: string[]): Promise<void> {
  // MapKit JS 5 can signal library loading with events, while newer releases
  // return a Promise. Confirm the required constructors themselves instead of
  // treating a partial `load` event as completion.
  await new Promise<void>((resolve, reject) => {
    let settled = false;
    let pollTimer: number | undefined;
    let timeoutTimer: number | undefined;
    const cleanup = () => {
      mk.removeEventListener?.('load', onLoad);
      mk.removeEventListener?.('load-error', onLoadError);
      if (pollTimer !== undefined) window.clearTimeout(pollTimer);
      if (timeoutTimer !== undefined) window.clearTimeout(timeoutTimer);
    };
    const finish = () => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve();
    };
    const fail = (error: unknown) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    };
    const hasRequiredConstructors = () => {
      try {
        return typeof mk.Map === 'function'
          && typeof mk.Coordinate === 'function'
          && typeof mk.PolygonOverlay === 'function'
          && typeof mk.PolylineOverlay === 'function'
          && typeof mk.Style === 'function'
          && typeof mk.Annotation === 'function'
          && typeof mk.CameraZoomRange === 'function';
      } catch {
        return false;
      }
    };
    const checkReady = () => { if (hasRequiredConstructors()) finish(); };
    const pollReady = () => {
      if (settled) return;
      checkReady();
      if (!settled) pollTimer = window.setTimeout(pollReady, 50);
    };
    const onLoad = () => checkReady();
    const onLoadError = (event: any) => fail(new Error(`MapKit JS のライブラリを読み込めませんでした: ${event?.status ?? 'unknown error'}`));
    try {
      mk.addEventListener?.('load', onLoad);
      mk.addEventListener?.('load-error', onLoadError);
      // The full MapKit JS bundle already contains these libraries and doesn't
      // expose `load`. Retain the dynamic-loader path for an existing page
      // which may still have the core bundle in memory during hot reload.
      if (typeof mk.load === 'function') {
        const result = mk.load(libraries);
        if (result && typeof result.then === 'function') {
          result.then(checkReady).catch(fail);
        }
      }
      timeoutTimer = window.setTimeout(() => fail(new Error(`MapKit JS のライブラリ (${libraries.join(', ')}) の読み込みが完了しませんでした。`)), 10_000);
      pollReady();
    } catch (error) {
      fail(error);
    }
  });
}

export function MapCanvas({ project, selected, mode, onAddPoint, onMovePoint, onFinishInteraction }: Props) {
  const node = useRef<HTMLDivElement>(null);
  const map = useRef<any>(undefined);
  const mapkit = useRef<any>(undefined);
  const modeRef = useRef(mode);
  const addPointRef = useRef(onAddPoint);
  const movePointRef = useRef(onMovePoint);
  const [message, setMessage] = useState('Apple Maps を準備しています…');
  const [mapReady, setMapReady] = useState(false);
  modeRef.current = mode;
  addPointRef.current = onAddPoint;
  movePointRef.current = onMovePoint;

  useEffect(() => {
    let cancelled = false;
    const initialize = async () => {
      try {
        const token = await fetch('/api/mapkit/token').then(async (response) => {
          if (!response.ok) throw new Error((await response.json()).message);
          return (await response.json()).token as string;
        });
        const mk = await loadMapKit();
        if (cancelled || !node.current) return;
        mk.init({ authorizationCallback: (done: (value: string) => void) => done(token), language: 'ja' });
        await loadMapLibraries(mk, ['map', 'overlays', 'annotations']);
        if (cancelled || !node.current) return;
        // Keep the exact namespace that created this map. Re-reading the
        // global namespace later can produce objects from a different loaded
        // MapKit library instance during a hot reload.
        mapkit.current = mk;
        map.current = new mk.Map(node.current, { mapType: mk.Map.MapTypes.Hybrid, showsCompass: mk.FeatureVisibility.Visible });
        // Keep the normal broad overview while allowing the + control and
        // pinch gesture to get close enough to position individual vertices.
        map.current.cameraZoomRange = new mk.CameraZoomRange(minimumEditCameraDistance, maximumCameraDistance);
        map.current.center = new mk.Coordinate(defaultMapCamera.lat, defaultMapCamera.lng);
        map.current.cameraDistance = defaultMapCamera.distance;
        map.current.addEventListener('single-tap', (event: any) => {
          if (modeRef.current !== 'add') return;
          const coordinate = event.pointOnPage
            ? map.current?.convertPointOnPageToCoordinate(event.pointOnPage)
            : event.coordinate;
          if (coordinate) addPointRef.current({ lat: coordinate.latitude, lng: coordinate.longitude });
        });
        setMessage('');
        setMapReady(true);
      } catch (error) {
        if (!cancelled) setMessage(error instanceof Error ? error.message : 'Apple Maps を初期化できませんでした。');
      }
    };
    void initialize();
    return () => {
      cancelled = true;
      setMapReady(false);
      map.current?.destroy?.();
      map.current = undefined;
      mapkit.current = undefined;
    };
  }, []);

  useEffect(() => {
    if (!mapReady) return;
    const current = map.current;
    if (!current) return;
    const mk = mapkit.current;
    if (!mk) return;
    try {
      // Replace the complete collection atomically. MapKit documents this
      // property as the supported way to update all overlays; it prevents
      // duplicate/re-entrant add calls while a coordinate field is edited.
      for (const annotation of current.annotations ?? []) current.removeAnnotation(annotation);
      const overlays: any[] = [];
      for (const object of project.objects.filter((item) => item.visible)) {
        if (object.geometry.type === 'point') continue;
        const coordinates = object.geometry.points.map((point) => new mk.Coordinate(point.lat, point.lng));
        if (coordinates.length < 2) continue;
        const color = objectColor(object);
        const style = {
          strokeColor: color,
          lineWidth: object.id === selected?.id ? 4 : object.style.strokeWidth ?? 2,
          fillColor: colorWithAlpha(color, object.kind === 'ashoreArea' ? '55' : '33'),
        };
        const overlayOptions = { style: new mk.Style(style), enabled: false };
        const overlay = object.geometry.type === 'polygon'
          ? new mk.PolygonOverlay(coordinates, overlayOptions)
          : new mk.PolylineOverlay(coordinates, overlayOptions);
        if (!(overlay instanceof mk.PolygonOverlay) && !(overlay instanceof mk.PolylineOverlay)) {
          throw new Error('MapKit のオーバーレイ生成を確認できませんでした。地図を再読み込みしてください。');
        }
        overlays.push(overlay);
      }
      for (const arrow of laneArrows(project)) {
        const annotation = new mk.Annotation(new mk.Coordinate(arrow.point.lat, arrow.point.lng), (_coordinate: any, _options: any) => {
          const element = document.createElement('div');
          element.className = 'lane-direction-arrow';
          // 文字の → は東(90度)を向くため、北基準の方位から90度引く。
          element.style.setProperty('--lane-arrow-rotation', `${arrow.bearingDegrees - 90}deg`);
          element.textContent = '➜';
          return element;
        }, {
          title: '航路レーンの規定進行方向',
          calloutEnabled: false,
          animates: false,
        });
        current.addAnnotation(annotation);
      }
      if (selected?.geometry.type === 'baseline' && selected.geometry.points.length > 1) {
        const shore = selected.kind === 'shore';
        for (const preview of dangerZonePreviews(selected.geometry.points, 5, shore ? 15 : 5, selected.geometry.closed)) {
          const overlay = new mk.PolygonOverlay(preview.full.map((point) => new mk.Coordinate(point.lat, point.lng)), {
            style: new mk.Style({ fillColor: shore ? '#8d6e6344' : '#ffb30044', strokeColor: '#ffb300' }),
            enabled: false,
          });
          if (overlay instanceof mk.PolygonOverlay) overlays.push(overlay);
        }
      }
      current.overlays = overlays;
      if (mode === 'move' && selected && !selected.locked && selected.geometry.type !== 'point') {
        const color = objectColor(selected);
        const annotations = selected.geometry.points.map((point, index) => {
          const annotation = new mk.Annotation(new mk.Coordinate(point.lat, point.lng), (_coordinate: any, options: any) => {
            const element = document.createElement('div');
            element.className = 'vertex-handle';
            element.textContent = String(options.data.index + 1);
            element.style.setProperty('--vertex-color', options.data.color);
            element.addEventListener('pointerdown', () => element.classList.add('is-pressed'));
            element.addEventListener('pointerup', () => element.classList.remove('is-pressed'));
            element.addEventListener('pointercancel', () => element.classList.remove('is-pressed'));
            return element;
          }, {
            title: `${selected.name || selected.exportId} の頂点 ${index + 1}`,
            draggable: true,
            calloutEnabled: false,
            animates: false,
            data: { index, color },
          });
          annotation.addEventListener('drag-start', () => annotation.element?.classList.add('is-dragging'));
          annotation.addEventListener('drag-end', () => {
            annotation.element?.classList.remove('is-dragging');
            const coordinate = annotation.coordinate;
            movePointRef.current(index, { lat: coordinate.latitude, lng: coordinate.longitude });
          });
          return annotation;
        });
        for (const annotation of annotations) current.addAnnotation(annotation);
      }
      setMessage('');
    } catch (error) {
      setMessage(error instanceof Error ? `地図オーバーレイを更新できませんでした: ${error.message}` : '地図オーバーレイを更新できませんでした。');
    }
  }, [mapReady, project, selected, mode]);

  const fallbackPoint = (event: React.PointerEvent<HTMLDivElement>) => {
    if (mode !== 'add' || map.current) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const lng = 140.09 + (event.clientX - rect.left) / rect.width * 0.14;
    const lat = 36.1 - (event.clientY - rect.top) / rect.height * 0.05;
    onAddPoint({ lat, lng });
  };
  return <div className="map-frame" ref={node} onPointerDown={fallbackPoint}>
    {message && <div className="map-fallback"><p>{message}</p><p>Apple Mapsの設定後に再読み込みしてください。設定前はこの概略座標面をクリックして作図できます。</p></div>}
    {mode === 'add' && <div className="draw-notice"><span>頂点追加モード: 地図をクリックして頂点を追加します</span><button onClick={onFinishInteraction}>追加を終了</button></div>}
    {mode === 'move' && <div className="draw-notice"><span>頂点移動モード: 番号付きの頂点をドラッグして移動します</span><button onClick={onFinishInteraction}>移動を終了</button></div>}
  </div>;
}
