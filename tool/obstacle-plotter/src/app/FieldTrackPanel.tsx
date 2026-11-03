import { useEffect, useState } from 'react';
import { sessionColor, sessionLabel, warningCategoryInfo, warningCategoryLabel, warningCountsByCategory, type FieldTrackSet } from '../model/fieldTracks';

const storageKey = 'obstacle-plotter.visibleTrackDates';

export function loadVisibleTrackDates(): Set<string> {
  try {
    const value = JSON.parse(localStorage.getItem(storageKey) ?? '[]');
    return new Set(Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []);
  } catch { return new Set(); }
}

function saveVisibleTrackDates(dates: ReadonlySet<string>) {
  try { localStorage.setItem(storageKey, JSON.stringify([...dates])); } catch { /* 保存できなくても表示は続ける */ }
}

const warningsKey = 'obstacle-plotter.fieldTrackWarnings';

/** 鳴った警告の表示設定（表示するか・隠す種類）。端末のブラウザにだけ保存する。 */
export type FieldWarningDisplay = { visible: boolean; hiddenCategories: Set<string> };

export function loadFieldWarningDisplay(): FieldWarningDisplay {
  try {
    const value = JSON.parse(localStorage.getItem(warningsKey) ?? '{}');
    return {
      visible: value.visible === true,
      hiddenCategories: new Set(Array.isArray(value.hiddenCategories) ? value.hiddenCategories.filter((item: unknown): item is string => typeof item === 'string') : []),
    };
  } catch { return { visible: false, hiddenCategories: new Set() }; }
}

function saveFieldWarningDisplay(display: FieldWarningDisplay) {
  try { localStorage.setItem(warningsKey, JSON.stringify({ visible: display.visible, hiddenCategories: [...display.hiddenCategories] })); } catch { /* 保存できなくても表示は続ける */ }
}

/** 実機ログの航跡を日付ごとに表示・非表示にする。作図データには触れない。 */
export function FieldTrackPanel({ visibleDates, onVisibleDatesChange, onLoaded, onFitRequest, warningDisplay, onWarningDisplayChange }: {
  visibleDates: ReadonlySet<string>;
  onVisibleDatesChange: (dates: Set<string>) => void;
  onLoaded: (set: FieldTrackSet | undefined) => void;
  onFitRequest: () => void;
  warningDisplay: FieldWarningDisplay;
  onWarningDisplayChange: (display: FieldWarningDisplay) => void;
}) {
  const [set, setSet] = useState<FieldTrackSet>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [expanded, setExpanded] = useState<string | null>(null);

  const load = async () => {
    setLoading(true);
    setError('');
    try {
      const response = await fetch('/api/field-tracks');
      const isJson = response.headers.get('content-type')?.includes('application/json');
      if (!isJson) throw new Error('航跡を読むAPIに接続できません。ツールは「npm run dev」で起動してください。');
      const result = await response.json();
      if (!response.ok) throw new Error(result.message ?? '実機ログを読めませんでした。');
      setSet(result as FieldTrackSet);
      onLoaded(result as FieldTrackSet);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : '実機ログを読めませんでした。');
      onLoaded(undefined);
    } finally { setLoading(false); }
  };
  useEffect(() => { void load(); }, []);

  const update = (next: Set<string>) => { saveVisibleTrackDates(next); onVisibleDatesChange(next); };
  const toggle = (date: string) => {
    const next = new Set(visibleDates);
    if (next.has(date)) next.delete(date); else next.add(date);
    update(next);
  };
  const days = set?.days ?? [];
  const sessionCount = days.reduce((sum, day) => sum + day.sessions.length, 0);
  const warningCounts = warningCountsByCategory(set, visibleDates);
  const updateWarnings = (next: FieldWarningDisplay) => { saveFieldWarningDisplay(next); onWarningDisplayChange(next); };
  const toggleCategory = (category: string) => {
    const hidden = new Set(warningDisplay.hiddenCategories);
    if (hidden.has(category)) hidden.delete(category); else hidden.add(category);
    updateWarnings({ ...warningDisplay, hiddenCategories: hidden });
  };

  return <section className="field-tracks">
    <div className="field-tracks-heading">
      <h2>実機ログの航跡</h2>
      <button onClick={() => void load()} disabled={loading}>{loading ? '読込中…' : '再読込'}</button>
    </div>
    {error && <p className="field-tracks-error">{error}</p>}
    {set && <p className="field-tracks-help">{days.length}日・{sessionCount}セッション。生の測位で、精度15m超の点と10秒超の途絶は描きません。表示専用で、書き出しには含めません。</p>}
    {days.length > 0 && <div className="field-tracks-actions">
      <button onClick={() => update(new Set(days.map((day) => day.date)))}>すべて表示</button>
      <button onClick={() => update(new Set())}>すべて隠す</button>
      <button onClick={onFitRequest} disabled={![...visibleDates].some((date) => days.some((day) => day.date === date))}>表示中へ移動</button>
    </div>}
    {days.length > 0 && <div className="field-warnings">
      <label><input type="checkbox" checked={warningDisplay.visible} onChange={() => updateWarnings({ ...warningDisplay, visible: !warningDisplay.visible })} /> 鳴った警告を表示</label>
      {warningDisplay.visible && <>
        <p className="field-tracks-help">表示中の日付で実際に鳴った警告を、鳴り始めの位置に印で出します。印の枠の色は航跡の色と同じです。印を押すと時刻と鳴り方が出ます。</p>
        {warningCounts.length === 0 && <p className="field-tracks-help">表示中の日付に、鳴った警告の記録はありません。</p>}
        <ul className="field-warning-categories">
          {warningCounts.map(([category, count]) => <li key={category}>
            <label>
              <input type="checkbox" checked={!warningDisplay.hiddenCategories.has(category)} onChange={() => toggleCategory(category)} />
              <span className="field-warning-mark" style={{ background: warningCategoryInfo[category]?.color ?? '#9e9e9e' }}>{warningCategoryInfo[category]?.mark ?? '？'}</span>
              {warningCategoryLabel(category)} {count}回
            </label>
          </li>)}
        </ul>
      </>}
    </div>}
    <ul className="field-track-days">
      {[...days].reverse().map((day) => <li key={day.date}>
        <div className="field-track-day">
          <label><input type="checkbox" checked={visibleDates.has(day.date)} onChange={() => toggle(day.date)} /> {day.date}</label>
          <button className="field-track-expand" onClick={() => setExpanded(expanded === day.date ? null : day.date)} aria-expanded={expanded === day.date}>{day.sessions.length}件 {expanded === day.date ? '▾' : '▸'}</button>
        </div>
        {expanded === day.date && <ul className="field-track-sessions">
          {day.sessions.map((session, index) => <li key={session.id} title={session.folder}>
            <span className="field-track-swatch" style={{ background: sessionColor(index) }} />
            <span>{sessionLabel(session)}</span>
          </li>)}
        </ul>}
      </li>)}
    </ul>
    {set && days.length === 0 && <p className="field-tracks-help">保存先に航跡がありません: {set.root}</p>}
  </section>;
}
