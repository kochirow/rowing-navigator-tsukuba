import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

describe('MapKit script loading', () => {
  let scripts: any[];
  beforeEach(() => {
    vi.resetModules();
    vi.useFakeTimers();
    scripts = [];
    vi.stubGlobal('window', { setTimeout, clearTimeout });
    vi.stubGlobal('document', {
      createElement: () => ({ remove: vi.fn() }),
      head: { append: (script: any) => scripts.push(script) },
    });
  });
  afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

  it('StrictModeの同時初期化でもSDKを一度だけ読み込む', async () => {
    const { loadMapKit } = await import('../src/map/loadMapKit');
    const first = loadMapKit();
    const second = loadMapKit();
    expect(scripts).toHaveLength(1);
    const sdk = {};
    (window as any).mapkit = sdk;
    scripts[0].onload();
    expect(await first).toBe(sdk);
    expect(await second).toBe(sdk);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('通信失敗後にスクリプトを除去して読み込み直せる', async () => {
    const { loadMapKit } = await import('../src/map/loadMapKit');
    const failed = expect(loadMapKit()).rejects.toThrow('通信');
    scripts[0].onerror();
    await failed;
    expect(scripts[0].remove).toHaveBeenCalledOnce();
    const retry = loadMapKit();
    expect(scripts).toHaveLength(2);
    (window as any).mapkit = {};
    scripts[1].onload();
    await retry;
  });

  it('SDKが応答しない場合も20秒で再試行可能になる', async () => {
    const { loadMapKit } = await import('../src/map/loadMapKit');
    const failed = expect(loadMapKit()).rejects.toThrow('再試行');
    await vi.advanceTimersByTimeAsync(20_000);
    await failed;
    expect(scripts[0].remove).toHaveBeenCalledOnce();
  });
});
