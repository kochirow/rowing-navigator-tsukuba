import { useEffect, useMemo, useState } from 'react';
import { exportGeoJson } from '../io/geojson';
import { exportKml } from '../io/kml';
import { exportLayout } from '../io/layout';
import { exportProfileText, importProfileText } from '../io/profile';
import { newFolder, newMapObject } from '../model/factories';
import type { Coordinate, Folder, MapObject, ObjectKind, Project } from '../model/types';
import { validateProject } from '../validate/project';
import { MapCanvas, type MapInteractionMode } from '../map/MapCanvas';
import { defaultObjectColor } from '../map/objectColor';
import { useProjectStore } from '../store/projectStore';
import { download } from './download';
import { prepareTemporaryObstacleImport, readTeamSafety } from '../io/firestore';
import { promoteTemporaryObject, temporaryObstacleObjects } from '../io/temporaryObstacles';

const kinds: Array<[ObjectKind, string]> = [
  ['shore', '岸（向きのある基準線）'], ['bridge', '橋（閉じた基準線）'], ['island', '中州（閉じた基準線）'],
  ['bridgePier', '橋脚（外周ポリゴン）'],
  ['driftwood', '流木（閉じた基準線）'], ['pile', '杭（外周ポリゴン）'], ['testZone', 'テスト区域'], ['curve', 'カーブ'], ['reverse', '逆走注意区域（旧データ用）'], ['generic', '危険区域'],
  ['ashoreArea', '陸上エリア（警告停止）'], ['navigableWater', '移動・一般水域（逆走判定なし）'], ['lane', '航路レーン'],
  ['practiceArea', '練習水域'], ['operationalCoverage', '対応水域'], ['channelCenterline', '航路中心線'],
];
const seven = (value: number) => value.toFixed(7);

function selected(project: Project): MapObject | undefined {
  return project.objects.find((object) => object.id === project.selectedObjectId);
}

function ObjectTree({ folders, objects, selectedId, selectedFolderId, onSelect, onSelectFolder, onToggleFolder, onAddChildFolder }: {
  folders: Folder[];
  objects: MapObject[];
  selectedId: string | null;
  selectedFolderId: string | null;
  onSelect: (id: string) => void;
  onSelectFolder: (id: string) => void;
  onToggleFolder: (id: string) => void;
  onAddChildFolder: (id: string) => void;
}) {
  const sortedFolders = (parentFolderId: string | null) => folders.filter((folder) => folder.parentFolderId === parentFolderId).sort((a, b) => a.order - b.order);
  const sortedObjects = (parentFolderId: string | null) => objects.filter((object) => object.parentFolderId === parentFolderId).sort((a, b) => a.order - b.order);
  const renderObject = (object: MapObject) => <button key={object.id} className={object.id === selectedId ? 'tree-item selected' : 'tree-item'} onClick={() => onSelect(object.id)}>
    <span>{object.visible ? '☑' : '☐'}{object.locked ? ' 🔒' : ''}</span><span>{object.name || object.exportId}</span><small>{object.geometry.type === 'point' ? 1 : object.geometry.points.length}点</small>
  </button>;
  const renderBranch = (parentFolderId: string | null, depth: number): React.ReactNode => <>
    {sortedFolders(parentFolderId).map((folder) => {
      const childCount = sortedObjects(folder.id).length;
      return <div className="tree-folder" key={folder.id}>
        <div className={folder.id === selectedFolderId ? 'tree-folder-header selected' : 'tree-folder-header'} style={{ paddingLeft: `${8 + depth * 14}px` }}>
          <button className="tree-folder-toggle" onClick={() => onToggleFolder(folder.id)} aria-label={`${folder.name} を${folder.expanded ? '折りたたむ' : '展開する'}`} aria-expanded={folder.expanded}>{folder.expanded ? '▾' : '▸'}</button>
          <button className="tree-folder-name" onClick={() => onSelectFolder(folder.id)}>📁 {folder.name}</button><small>{childCount}件</small>
          <button className="tree-folder-add" onClick={() => onAddChildFolder(folder.id)} aria-label={`${folder.name}の中にフォルダを追加`}>＋</button>
        </div>
        {folder.expanded && <div className="tree-folder-contents">
          {sortedObjects(folder.id).map(renderObject)}
          {renderBranch(folder.id, depth + 1)}
        </div>}
      </div>;
    })}
    {parentFolderId === null && sortedObjects(null).map(renderObject)}
  </>;
  return <div className="tree">{renderBranch(null, 0)}</div>;
}

export default function App() {
  const store = useProjectStore();
  const project = store.project;
  const current = selected(project);
  const [selectedFolderId, setSelectedFolderId] = useState<string | null>(null);
  const currentFolder = project.folders.find((folder) => folder.id === selectedFolderId);
  const [mapMode, setMapMode] = useState<MapInteractionMode>('pan');
  const [newKind, setNewKind] = useState<ObjectKind>('ashoreArea');
  const [serverMessage, setServerMessage] = useState('');
  const [inviteCode, setInviteCode] = useState('');
  const [importingTemporary, setImportingTemporary] = useState(false);
  const [creatingChangeset, setCreatingChangeset] = useState(false);
  const issues = useMemo(() => validateProject(project), [project]);

  useEffect(() => { void store.loadLast(); }, []);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement || event.target instanceof HTMLSelectElement) return;
      if (event.key === 'Escape' || event.key === 'Enter') setMapMode('pan');
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const replace = (next: Project) => store.replace(next);
  const addPoint = (point: Coordinate) => {
    if (!current || current.locked || current.geometry.type === 'point') return;
    store.updateObject(current.id, (object) => {
      if (object.geometry.type === 'point') return object;
      return { ...object, geometry: { ...object.geometry, points: [...object.geometry.points, point] } };
    });
  };
  const movePoint = (index: number, point: Coordinate) => {
    if (!current || current.locked || current.geometry.type === 'point') return;
    store.updateObject(current.id, (object) => {
      if (object.geometry.type === 'point') return object;
      return { ...object, geometry: { ...object.geometry, points: object.geometry.points.map((candidate, candidateIndex) => candidateIndex === index ? point : candidate) } };
    });
  };
  const createObject = () => {
    if (['practiceArea', 'operationalCoverage'].includes(newKind) && project.objects.some((object) => object.kind === newKind)) {
      setServerMessage(`${kinds.find(([kind]) => kind === newKind)?.[1]} は1つだけ作成できます。`);
      return;
    }
    const created = newMapObject(newKind);
    // 親の橋を選んでから追加すれば、取り違えや手入力漏れを避けられる。
    const centerlines = project.objects.filter((candidate) => candidate.kind === 'channelCenterline');
    const object = newKind === 'bridgePier' && current?.kind === 'bridge'
      ? { ...created, bridgeId: current.exportId }
      : newKind === 'lane'
        ? {
            ...created,
            centerlineId: current?.kind === 'channelCenterline'
              ? current.exportId
              : centerlines.length === 1
                ? centerlines[0].exportId
                : undefined,
          }
        : created;
    setSelectedFolderId(null);
    replace({ ...project, objects: [...project.objects, object], selectedObjectId: object.id });
    setMapMode('add');
  };
  const createFolder = (parentFolderId: string | null = selectedFolderId) => {
    const order = Math.max(-1, ...project.folders.filter((folder) => folder.parentFolderId === parentFolderId).map((folder) => folder.order)) + 1;
    const folder = newFolder('新しいフォルダ', parentFolderId, order);
    replace({ ...project, folders: [...project.folders, folder] });
    setSelectedFolderId(folder.id);
    setMapMode('pan');
  };
  const importBundled = async () => {
    try {
      const response = await fetch('/api/profile');
      if (!response.ok) throw new Error('ローカルサーバーからプロファイルを読めませんでした。');
      const imported = await importProfileText(await response.text());
      store.replace(imported, false);
      setServerMessage('同梱プロファイルを読み込みました。');
    } catch (error) { setServerMessage(error instanceof Error ? error.message : '読み込みに失敗しました。'); }
  };
  const importFile = async (file: File | undefined) => {
    if (!file) return;
    try { store.replace(await importProfileText(await file.text()), false); setServerMessage(`${file.name} を読み込みました。`); }
    catch (error) { setServerMessage(error instanceof Error ? error.message : 'JSONを読み込めませんでした。'); }
  };
  const makeChangeset = async () => {
    const errors = issues.filter((item) => item.level === 'error');
    setCreatingChangeset(true);
    setServerMessage(errors.length
      ? `検証エラー ${errors.length} 件を含む未完成パッケージを作成しています…`
      : '変更適用パッケージを作成しています…');
    try {
      const controller = new AbortController();
      const timeout = window.setTimeout(() => controller.abort(), 15_000);
      const response = await fetch('/api/changeset', {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(project), signal: controller.signal,
      }).finally(() => window.clearTimeout(timeout));
      const responseText = await response.text();
      const isJson = response.headers.get('content-type')?.includes('application/json');
      if (!isJson) {
        throw new Error('変更適用APIに接続できません。ツールは「npm run dev」で起動してください（「npm run dev:offline」ではパッケージを作成できません）。');
      }
      let result: { message?: string; path?: string };
      try { result = JSON.parse(responseText) as { message?: string; path?: string }; }
      catch { throw new Error('変更適用APIから不正な応答が返りました。ターミナルのエラーを確認して「npm run dev」を再起動してください。'); }
      if (!response.ok) throw new Error(result.message ?? `変更適用パッケージを作成できませんでした（HTTP ${response.status}）。`);
      if (!result.path) throw new Error('変更適用パッケージの保存先を確認できませんでした。ターミナルのログを確認してください。');
      setServerMessage(errors.length
        ? `未完成パッケージを作成しました（検証エラー ${errors.length} 件付き）。AIエージェントに changeset.json の validation も渡してください。保存先: ${result.path}`
        : `変更適用パッケージを作成しました。保存先: ${result.path}`);
    } catch (error) {
      const message = error instanceof DOMException && error.name === 'AbortError'
        ? '15秒以内に変更適用パッケージを作成できませんでした。ターミナルのエラーを確認して「npm run dev」を再起動してください。'
        : error instanceof Error ? error.message : '変更適用パッケージを作成できませんでした。';
      setServerMessage(message);
    } finally { setCreatingChangeset(false); }
  };
  const importTemporary = async () => {
    setImportingTemporary(true);
    try {
      const { teamId } = await prepareTemporaryObstacleImport(inviteCode);
      const safety = await readTeamSafety(teamId);
      const result = temporaryObstacleObjects(safety.temporaryObstacles);
      const knownDocumentIds = new Set(project.objects.flatMap((object) => object.origin.kind === 'temporary' ? [object.origin.docId] : []));
      const additions = result.objects.filter((object) => !knownDocumentIds.has(object.origin.kind === 'temporary' ? object.origin.docId : ''));
      if (additions.length === 0) {
        setServerMessage(result.skipped.length ? `新規の臨時障害物はありません（無効 ${result.skipped.length} 件）。` : '新規の臨時障害物はありません。');
        return;
      }
      replace({
        ...project,
        objects: [...project.objects, ...additions],
        importedFrom: { ...project.importedFrom, teamId, temporaryFetchedAt: new Date().toISOString() },
        selectedObjectId: additions[0].id,
      });
      setServerMessage(`${additions.length}件を「臨時（取込）」へ追加しました。航空写真と現地記録で確認後に昇格してください。${result.skipped.length ? ` 無効 ${result.skipped.length}件は除外しました。` : ''}`);
    } catch (error) {
      setServerMessage(error instanceof Error ? error.message : '臨時障害物を取り込めませんでした。');
    } finally { setImportingTemporary(false); }
  };
  const promote = (object: MapObject, kind: ObjectKind, exportId: string) => {
    try {
      const next = promoteTemporaryObject(object, kind, exportId);
      if (project.objects.some((candidate) => candidate.id !== object.id && candidate.exportId === next.exportId)) {
        throw new Error('このexport IDは既に使われています。');
      }
      store.updateObject(object.id, () => next);
      setServerMessage(`「${next.name}」を固定候補へ昇格しました。変更適用パッケージを作成し、配布版の確認後に元の臨時障害物をアプリで削除してください。`);
    } catch (error) { setServerMessage(error instanceof Error ? error.message : '固定候補へ昇格できませんでした。'); }
  };
  return <main>
    <header className="toolbar">
      <h1>桜川 障害物座標プロット</h1>
      <button onClick={() => replace({ ...project, objects: [], selectedObjectId: null })}>新規</button>
      <button onClick={importBundled}>同梱JSONを読込</button>
      <label className="button">ファイルを読込<input type="file" accept="application/json,.json" onChange={(event) => void importFile(event.target.files?.[0])} /></label>
      <button onClick={() => download('sakuragawa_obstacles.json', exportProfileText(project))}>JSON書出</button>
      <button onClick={() => download('sakuragawa_obstacles.layout.json', exportLayout(project))}>レイアウト書出</button>
      <button onClick={() => download('sakuragawa_obstacles.geojson', exportGeoJson(project), 'application/geo+json')}>GeoJSON</button>
      <button onClick={() => download('sakuragawa_obstacles.kml', exportKml(project), 'application/vnd.google-earth.kml+xml')}>KML</button>
      <label>プロファイル版<input type="number" min="1" step="1" value={project.profileVersion} onChange={(event) => { const version = Number(event.target.value); if (Number.isInteger(version) && version > 0) replace({ ...project, profileVersion: version }); }} /></label>
      <label>招待コード（初回のみ）<input value={inviteCode} onChange={(event) => setInviteCode(event.target.value)} placeholder="XXXX-XXXX-XXXX" /></label>
      <button onClick={() => void importTemporary()} disabled={importingTemporary}>{importingTemporary ? '取込中…' : '臨時障害物を取込'}</button>
      <button className="primary" onClick={() => void makeChangeset()} disabled={creatingChangeset}>{creatingChangeset ? 'パッケージ作成中…' : '変更適用パッケージ'}</button>
      <button onClick={store.undo} disabled={store.history.length === 0}>戻す</button>
      <button onClick={store.redo} disabled={store.future.length === 0}>進む</button>
    </header>
    <section className="workspace">
      <aside className="sidebar">
        <div className="new-object"><select value={newKind} onChange={(event) => setNewKind(event.target.value as ObjectKind)}>{kinds.map(([kind, label]) => <option key={kind} value={kind}>{label}</option>)}</select><button onClick={createObject}>＋ 作成</button></div>
        <button className="new-folder" onClick={() => createFolder()}>＋ フォルダを追加{currentFolder ? `（${currentFolder.name}内）` : ''}</button>
        <div className="map-tools" aria-label="地図操作">
          <div className="map-tools-heading"><span>地図操作</span><small>{current ? `${current.name || current.exportId}${current.locked ? '（ロック中）' : ''}` : 'まずオブジェクトを選択'}</small></div>
          <button className={mapMode === 'pan' ? 'active' : ''} onClick={() => setMapMode('pan')}>地図を移動</button>
          <button className={mapMode === 'add' ? 'active' : ''} onClick={() => setMapMode('add')} disabled={!current || current.locked || current.geometry.type === 'point'}>頂点を追加</button>
          <button className={mapMode === 'move' ? 'active' : ''} onClick={() => setMapMode('move')} disabled={!current || current.locked || current.geometry.type === 'point'}>頂点を移動</button>
          <button className="map-tools-finish" onClick={() => setMapMode('pan')} disabled={mapMode === 'pan'}>操作を終了</button>
          <p className="map-tools-help">追加は地図をクリック、移動は番号付き頂点をドラッグ。「操作を終了」で通常の地図操作へ戻ります。</p>
        </div>
        <h2>オブジェクト</h2>
        <ObjectTree folders={project.folders} objects={project.objects} selectedId={selectedFolderId ? null : current?.id ?? null} selectedFolderId={selectedFolderId} onSelect={(id) => { setSelectedFolderId(null); store.select(id); }} onSelectFolder={(id) => { setSelectedFolderId(id); setMapMode('pan'); }} onToggleFolder={(id) => store.updateFolder(id, (folder) => ({ ...folder, expanded: !folder.expanded }), false)} onAddChildFolder={createFolder} />
        <h2>検証</h2>
        <div className="issues">{issues.map((item, index) => <p className={item.level} key={`${item.code}-${index}`}>{item.level === 'error' ? '⛔' : '⚠'} {item.message}</p>)}</div>
      </aside>
      <section className="map-panel"><MapCanvas project={project} selected={current} mode={mapMode} onAddPoint={addPoint} onMovePoint={movePoint} onFinishInteraction={() => setMapMode('pan')} /></section>
      <aside className="inspector">{currentFolder ? <FolderInspector folder={currentFolder} folders={project.folders} onChange={(folder) => store.updateFolder(folder.id, () => folder)} /> : <Inspector object={current} objects={project.objects} folders={project.folders} onChange={(object) => store.updateObject(object.id, () => object)} onSelect={store.select} onDrawing={() => setMapMode('add')} onMoving={() => setMapMode('move')} onPromote={promote} />}</aside>
    </section>
    {serverMessage && <div className="action-notice" role="status" aria-live="polite"><span>{serverMessage}</span><button onClick={() => setServerMessage('')} aria-label="通知を閉じる">×</button></div>}
    <footer><span>{store.loaded ? '保存済み' : '復元中…'} {new Date(project.updatedAt).toLocaleTimeString('ja-JP')}</span><span>選択: {current?.name ?? 'なし'}</span><span>{issues.filter((issue) => issue.level === 'error').length ? `⛔ エラー ${issues.filter((issue) => issue.level === 'error').length}件` : `⚠ 注意 ${issues.length}件`}</span></footer>
  </main>;
}

function CoordinateInput({ value, axis, disabled, onCommit }: { value: number; axis: 'lat' | 'lng'; disabled: boolean; onCommit: (value: number) => void }) {
  const [draft, setDraft] = useState(seven(value));
  useEffect(() => setDraft(seven(value)), [value]);
  const commit = () => {
    const next = Number(draft);
    const maximum = axis === 'lat' ? 90 : 180;
    if (Number.isFinite(next) && Math.abs(next) <= maximum) onCommit(next);
    else setDraft(seven(value));
  };
  return <input value={draft} onChange={(event) => setDraft(event.target.value)} onBlur={commit} onKeyDown={(event) => {
    if (event.key === 'Enter') event.currentTarget.blur();
    if (event.key === 'Escape') { setDraft(seven(value)); event.currentTarget.blur(); }
  }} disabled={disabled} />;
}

function Inspector({ object, objects, folders, onChange, onSelect, onDrawing, onMoving, onPromote }: { object: MapObject | undefined; objects: MapObject[]; folders: Folder[]; onChange: (object: MapObject) => void; onSelect: (id: string | null) => void; onDrawing: () => void; onMoving: () => void; onPromote: (object: MapObject, kind: ObjectKind, exportId: string) => void }) {
  if (!object) return <div className="empty">オブジェクトを選択してください。</div>;
  const points = object.geometry.type === 'point' ? [object.geometry.point] : object.geometry.points;
  const patch = (partial: Partial<MapObject>) => onChange({ ...object, ...partial });
  const updatePoint = (index: number, key: 'lat' | 'lng', number: number) => {
    const geometry = object.geometry;
    if (geometry.type === 'point') return;
    const next = geometry.points.map((point, pointIndex) => pointIndex === index ? { ...point, [key]: number } : point);
    patch({ geometry: { ...geometry, points: next } } as Partial<MapObject>);
  };
  const deletePoint = (index: number) => {
    const geometry = object.geometry;
    if (geometry.type === 'point') return;
    patch({ geometry: { ...geometry, points: geometry.points.filter((_, pointIndex) => pointIndex !== index) } } as Partial<MapObject>);
  };
  return <div className="inspector-body">
    <h2>オブジェクト情報</h2>
    <label>名前<input value={object.name} onChange={(event) => patch({ name: event.target.value })} /></label>
    <label>export ID<input value={object.exportId} onChange={(event) => patch({ exportId: event.target.value.toLowerCase() })} /></label>
    {object.kind === 'bridgePier' && <label>親の橋<select value={object.bridgeId ?? ''} onChange={(event) => patch({ bridgeId: event.target.value || undefined })} disabled={object.locked}><option value="">選択してください</option>{objects.filter((candidate) => candidate.kind === 'bridge').sort((a, b) => a.name.localeCompare(b.name, 'ja')).map((bridge) => <option value={bridge.exportId} key={bridge.id}>{bridge.name || bridge.exportId}</option>)}</select></label>}
    {object.kind === 'bridgePier' && <p className="folder-help">橋脚の実際の外周を、3点以上で直接囲んでください。橋桁全体・影・周囲の余裕幅は含めません。形状が不明な場合は、確認状況を「draft」または「航空写真で確認」のままにして現地確認へつなげてください。</p>}
    {object.kind === 'pile' && <p className="folder-help">水中に立つ杭の実際の外周を、3点以上で直接囲んでください。周囲の余裕幅や推定の幅は含めません。杭の中心点だけで登録せず、航空写真で見える輪郭をそのままプロットします。</p>}
    <label>説明<textarea value={object.description} onChange={(event) => patch({ description: event.target.value })} /></label>
    <label>フォルダ<select value={object.parentFolderId ?? ''} onChange={(event) => patch({ parentFolderId: event.target.value || null })} disabled={object.locked}><option value="">未分類</option>{folders.slice().sort((a, b) => a.name.localeCompare(b.name, 'ja')).map((folder) => <option value={folder.id} key={folder.id}>{folder.name}</option>)}</select></label>
    {object.kind === 'lane' && <fieldset className="lane-direction" disabled={object.locked}>
      <legend>規定進行方向</legend>
      <label>基準にする航路中心線<select value={object.centerlineId ?? ''} onChange={(event) => patch({ centerlineId: event.target.value || undefined })}><option value="">選択してください</option>{objects.filter((candidate) => candidate.kind === 'channelCenterline').sort((a, b) => a.name.localeCompare(b.name, 'ja')).map((centerline) => <option value={centerline.exportId} key={centerline.id}>{centerline.name || centerline.exportId}</option>)}</select></label>
      <p>選択した中心線の頂点順を基準にします。霞ヶ浦、桜川河口、桜川上流のように航路が分かれる場合は、区間ごとの中心線を選んでください。移動水域にはレーンを重ねません。</p>
      <label><input type="radio" name={`lane-direction-${object.id}`} checked={object.laneDirection === 'along'} onChange={() => patch({ laneDirection: 'along' })} /> 中心線の向きと同じ</label>
      <label><input type="radio" name={`lane-direction-${object.id}`} checked={object.laneDirection === 'against'} onChange={() => patch({ laneDirection: 'against' })} /> 中心線の向きと逆</label>
    </fieldset>}
    {object.kind === 'lane' && <fieldset className="lane-direction" disabled={object.locked}>
      <legend>往路・復路（表示専用）</legend>
      <p>アプリが地図でグレーの濃淡に塗り分けるためだけに使います。<strong>安全判定（逆走）には使いません。</strong>上の「規定進行方向」とは無関係で、桜川河口の往路のように「往路なのに中心線とは逆向き」の組み合わせが実際にあります。片方から他方を推測せず、人が呼んでいるとおりに選んでください。</p>
      <label><input type="radio" name={`lane-leg-${object.id}`} checked={object.laneLeg === 'outbound'} onChange={() => patch({ laneLeg: 'outbound' })} /> 往路</label>
      <label><input type="radio" name={`lane-leg-${object.id}`} checked={object.laneLeg === 'return'} onChange={() => patch({ laneLeg: 'return' })} /> 復路</label>
      <div className="style-actions"><button onClick={() => patch({ laneLeg: undefined })} disabled={object.locked || !object.laneLeg}>未設定に戻す</button></div>
    </fieldset>}
    {object.kind === 'channelCenterline' && <p className="folder-help">同じ区間の往路・復路が同じ軸を共有できる場合、中心線は1本で十分です。現在の想定では「霞ヶ浦」「桜川河口」「桜川上流」の3本を基本にします。河口と上流の間の移動水域では中心線・レーンを中断してください。</p>}
    {object.kind === 'navigableWater' && <p className="folder-help">移動水域は表示用の水面です。方向と中心線を持たず、逆走判定には使いません。河口レーンと上流レーンの間をこの水域だけにすると、判定が中断し、上流レーンへ入ると再開します。</p>}
    <label>表示色<input type="color" value={object.style.color ?? defaultObjectColor(object.exportId || object.id)} onChange={(event) => patch({ style: { ...object.style, color: event.target.value } })} disabled={object.locked} /></label>
    <div className="style-actions"><button onClick={() => patch({ style: { ...object.style, color: undefined } })} disabled={object.locked || !object.style.color}>自動色に戻す</button></div>
    <label>確認状況<select value={object.verificationStatus} onChange={(event) => patch({ verificationStatus: event.target.value as MapObject['verificationStatus'] })}><option value="draft">draft</option><option value="aerial_only">航空写真で確認</option><option value="field_verified">現地確認済み</option><option value="field_calibrated">現地校正済み</option><option value="needs_review">要再確認</option></select></label>
    {object.origin.kind === 'temporary' && <PromotionControls object={object} onPromote={onPromote} />}
    <div className="inspector-actions"><button onClick={onDrawing} disabled={object.locked || object.geometry.type === 'point'}>頂点を追加</button><button onClick={onMoving} disabled={object.locked || object.geometry.type === 'point'}>頂点を移動</button>{object.kind === 'shore' && object.geometry.type === 'baseline' && <button onClick={() => {
      const geometry = object.geometry;
      if (geometry.type === 'baseline') patch({ geometry: { ...geometry, points: [...geometry.points].reverse() } } as Partial<MapObject>);
    }} disabled={object.locked}>向きを反転</button>}{object.kind === 'channelCenterline' && object.geometry.type === 'polyline' && <button onClick={() => {
      const geometry = object.geometry;
      if (geometry.type === 'polyline') patch({ geometry: { ...geometry, points: [...geometry.points].reverse() } } as Partial<MapObject>);
    }} disabled={object.locked}>中心線の向きを反転</button>}<button onClick={() => patch({ locked: !object.locked })}>{object.locked ? 'ロック解除' : 'ロック'}</button><button onClick={() => onSelect(null)}>選択解除</button></div>
    <h3>座標一覧（{points.length}点）</h3><p className="coordinate-help">値は入力欄を離れるかEnterで確定します。Escで変更を取り消せます。</p><div className="coordinate-table">{points.map((point, index) => <div className="coordinate-row" key={index}><span>{index + 1}</span><CoordinateInput value={point.lat} axis="lat" onCommit={(value) => updatePoint(index, 'lat', value)} disabled={object.locked} /><CoordinateInput value={point.lng} axis="lng" onCommit={(value) => updatePoint(index, 'lng', value)} disabled={object.locked} /><button onClick={() => deletePoint(index)} disabled={object.locked}>削除</button></div>)}</div>
  </div>;
}

function FolderInspector({ folder, folders, onChange }: { folder: Folder; folders: Folder[]; onChange: (folder: Folder) => void }) {
  const descendants = new Set<string>();
  const addDescendants = (parentId: string) => {
    for (const child of folders.filter((candidate) => candidate.parentFolderId === parentId)) {
      if (descendants.has(child.id)) continue;
      descendants.add(child.id);
      addDescendants(child.id);
    }
  };
  addDescendants(folder.id);
  const parents = folders.filter((candidate) => candidate.id !== folder.id && !descendants.has(candidate.id)).sort((a, b) => a.name.localeCompare(b.name, 'ja'));
  const patch = (partial: Partial<Folder>) => onChange({ ...folder, ...partial });
  return <div className="inspector-body">
    <h2>フォルダ情報</h2>
    <label>名前<input value={folder.name} onChange={(event) => patch({ name: event.target.value })} /></label>
    <label>親フォルダ<select value={folder.parentFolderId ?? ''} onChange={(event) => patch({ parentFolderId: event.target.value || null })}><option value="">最上位</option>{parents.map((candidate) => <option value={candidate.id} key={candidate.id}>{candidate.name}</option>)}</select></label>
    <p className="folder-help">親に自分自身や子フォルダは選べません。フォルダを選択した状態で「＋ フォルダを追加」を押すと、その中に作成できます。</p>
  </div>;
}

function PromotionControls({ object, onPromote }: { object: MapObject; onPromote: (object: MapObject, kind: ObjectKind, exportId: string) => void }) {
  const [promotionKind, setPromotionKind] = useState<ObjectKind>('driftwood');
  const [promotionId, setPromotionId] = useState(object.exportId);
  return <section>
    <h3>固定障害物へ昇格</h3>
    <p>地図上の形状を確認してから昇格してください。元のFirestore文書は、配布版で確認するまで削除しません。</p>
    <label>種別<select value={promotionKind} onChange={(event) => setPromotionKind(event.target.value as ObjectKind)}><option value="driftwood">流木</option><option value="pile">杭</option><option value="generic">一般障害物</option><option value="island">中州</option><option value="bridge">橋</option></select></label>
    <label>固定用 export ID<input value={promotionId} onChange={(event) => setPromotionId(event.target.value)} /></label>
    <button className="primary" onClick={() => onPromote(object, promotionKind, promotionId)}>固定候補へ昇格</button>
  </section>;
}
