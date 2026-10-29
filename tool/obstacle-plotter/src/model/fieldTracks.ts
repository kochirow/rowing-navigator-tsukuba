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

export function sessionLabel(session: FieldTrackSession): string {
  const time = new Date(Date.parse(session.startedAt) + 9 * 3_600_000).toISOString().slice(11, 16);
  const boat = session.boatType ? session.boatType.replace(/^r_/, '') : '艇種不明';
  return [time, boat, session.seatPosition ? `(${session.seatPosition})` : '', session.provider ?? ''].filter(Boolean).join(' ');
}
