/** 実機ログの航跡(表示専用)。作図データ(Project)には入れず、書き出しにも含めない。 */
export type FieldTrackSession = {
  id: string;
  /** 日本時間の日付(YYYY-MM-DD) */
  date: string;
  startedAt: string;
  boatType?: string;
  seatPosition?: string;
  appVersion?: string;
  /** 診断バンドルの提供者名(バンドルのフォルダ名から) */
  provider?: string;
  /** 保存先からの相対パス */
  folder: string;
  pointCount: number;
  /** [lat, lng] の線分。精度の悪い点と途絶で切ってある */
  segments: Array<Array<[number, number]>>;
  /** 実際に鳴った警告（警告音の再生要求）。古いログでは空 */
  warnings?: FieldTrackWarning[];
};

/**
 * 実機で鳴った警告1回。`events.jsonl` の `warning_presentation_requested` から作る。
 * 位置はその時刻にいちばん近い測位（`raw_lat`/`raw_lng`）。
 */
export type FieldTrackWarning = {
  at: string;
  lat: number;
  lng: number;
  /** 警告の種類（`other_boat`・`shore`・`reverse` など、アプリのカテゴリ名） */
  category: string;
  /** 鳴り方（`loop` = 繰り返し、`playOnce` = 1回） */
  mode: string;
  /** 次の停止・切り替えまでの秒数。繰り返しの警告で「どれだけ鳴っていたか」の目安 */
  durationSec?: number;
};

export type FieldTrackDay = { date: string; sessions: FieldTrackSession[] };
export type FieldTrackSet = { root: string; days: FieldTrackDay[] };

/** 地図へ渡す1本の線。 */
export type FieldTrackLine = { key: string; color: string; points: Array<[number, number]> };

// 衛星写真の上で見分けやすい明るい色。作図オブジェクトの色と被りにくいものを選ぶ。
const palette = ['#ff4fd8', '#00e5ff', '#ffe600', '#7cff4f', '#ff8a3d', '#b388ff', '#ff5252', '#40c4ff', '#eeff41', '#69f0ae'];

export function sessionColor(index: number): string {
  return palette[index % palette.length];
}

/** 表示中の日付の航跡を、地図に渡す線へ展開する。色はその日の中のセッション順で決める。 */
export function visibleFieldTrackLines(set: FieldTrackSet | undefined, visibleDates: ReadonlySet<string>): FieldTrackLine[] {
  if (!set) return [];
  const lines: FieldTrackLine[] = [];
  for (const day of set.days) {
    if (!visibleDates.has(day.date)) continue;
    day.sessions.forEach((session, index) => {
      session.segments.forEach((points, segmentIndex) => {
        lines.push({ key: `${session.id}:${segmentIndex}`, color: sessionColor(index), points });
      });
    });
  }
  return lines;
}

/** 警告の種類の表示名と、地図の印に書く1文字。アプリの読み上げに合わせる。 */
export const warningCategoryInfo: Record<string, { label: string; mark: string; color: string }> = {
  other_boat: { label: '他艇', mark: '艇', color: '#e53935' },
  shore: { label: '岸', mark: '岸', color: '#8d6e63' },
  bridge: { label: '橋', mark: '橋', color: '#5e35b1' },
  bridgePier: { label: '橋脚', mark: '脚', color: '#3949ab' },
  pile: { label: '杭', mark: '杭', color: '#f4511e' },
  driftwood: { label: '流木', mark: '流', color: '#6d4c41' },
  island: { label: '中州', mark: '州', color: '#43a047' },
  curve: { label: 'カーブ', mark: '曲', color: '#00897b' },
  reverse: { label: '逆走注意', mark: '逆', color: '#fb8c00' },
  testZone: { label: 'テスト区域', mark: '試', color: '#757575' },
  // 2026-08 より前の版では、通信・測位の不調も読み上げていた(いまは表示だけ)。
  gps_unavailable: { label: 'GPS途絶（旧版）', mark: 'G', color: '#546e7a' },
  other_boat_receive_unavailable: { label: '他艇の受信不良（旧版）', mark: '受', color: '#546e7a' },
  position_sharing_unavailable: { label: '位置共有の不調（旧版）', mark: '共', color: '#546e7a' },
  pipeline_unresponsive: { label: '評価停止（旧版）', mark: '停', color: '#546e7a' },
};

export function warningCategoryLabel(category: string): string {
  return warningCategoryInfo[category]?.label ?? category;
}

/** 地図へ渡す警告の印1つ。 */
export type FieldTrackWarningMarker = {
  key: string;
  lat: number;
  lng: number;
  category: string;
  mark: string;
  categoryColor: string;
  /** 航跡の線と同じ色。どのセッションの警告かを枠の色で示す */
  sessionColor: string;
  title: string;
  subtitle: string;
};

function japanTime(iso: string): string {
  const time = Date.parse(iso);
  return Number.isFinite(time) ? new Date(time + 9 * 3_600_000).toISOString().slice(11, 19) : iso;
}

/**
 * 表示中の日付の警告を、地図の印へ展開する。
 * [hiddenCategories] に入った種類は出さない（種類ごとのオン・オフ）。
 */
export function visibleFieldTrackWarnings(
  set: FieldTrackSet | undefined,
  visibleDates: ReadonlySet<string>,
  hiddenCategories: ReadonlySet<string> = new Set(),
): FieldTrackWarningMarker[] {
  if (!set) return [];
  const markers: FieldTrackWarningMarker[] = [];
  for (const day of set.days) {
    if (!visibleDates.has(day.date)) continue;
    day.sessions.forEach((session, index) => {
      (session.warnings ?? []).forEach((warning, warningIndex) => {
        if (hiddenCategories.has(warning.category)) return;
        const info = warningCategoryInfo[warning.category];
        const howLong = warning.mode === 'loop'
          ? `繰り返し${warning.durationSec !== undefined ? `・約${Math.round(warning.durationSec)}秒` : ''}`
          : '1回';
        markers.push({
          key: `${session.id}:w${warningIndex}`,
          lat: warning.lat,
          lng: warning.lng,
          category: warning.category,
          mark: info?.mark ?? '？',
          categoryColor: info?.color ?? '#9e9e9e',
          sessionColor: sessionColor(index),
          title: `${japanTime(warning.at)} ${warningCategoryLabel(warning.category)}（${howLong}）`,
          subtitle: sessionLabel(session),
        });
      });
    });
  }
  return markers;
}

/** 表示中の日付で、種類ごとに何回鳴ったか（種類のオン・オフの横に出す）。 */
export function warningCountsByCategory(set: FieldTrackSet | undefined, visibleDates: ReadonlySet<string>): Array<[string, number]> {
  const counts = new Map<string, number>();
  for (const day of set?.days ?? []) {
    if (!visibleDates.has(day.date)) continue;
    for (const session of day.sessions) {
      for (const warning of session.warnings ?? []) counts.set(warning.category, (counts.get(warning.category) ?? 0) + 1);
    }
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1]);
}

export function sessionLabel(session: FieldTrackSession): string {
  const time = new Date(Date.parse(session.startedAt) + 9 * 3_600_000).toISOString().slice(11, 16);
  const boat = session.boatType ? session.boatType.replace(/^r_/, '') : '艇種不明';
  return [time, boat, session.seatPosition ? `(${session.seatPosition})` : '', session.provider ?? ''].filter(Boolean).join(' ');
}
