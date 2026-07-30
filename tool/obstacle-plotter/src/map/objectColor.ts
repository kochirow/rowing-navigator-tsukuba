import type { MapObject } from '../model/types';

function hslToHex(hue: number, saturation: number, lightness: number): string {
  const s = saturation / 100;
  const l = lightness / 100;
  const chroma = (1 - Math.abs(2 * l - 1)) * s;
  const section = hue / 60;
  const second = chroma * (1 - Math.abs(section % 2 - 1));
  const [red, green, blue] = section < 1 ? [chroma, second, 0]
    : section < 2 ? [second, chroma, 0]
      : section < 3 ? [0, chroma, second]
        : section < 4 ? [0, second, chroma]
          : section < 5 ? [second, 0, chroma]
            : [chroma, 0, second];
  const offset = l - chroma / 2;
  return `#${[red, green, blue].map((value) => Math.round((value + offset) * 255).toString(16).padStart(2, '0')).join('')}`;
}

export function defaultObjectColor(key: string): string {
  let hash = 0;
  for (const character of key) hash = (hash * 31 + character.charCodeAt(0)) | 0;
  return hslToHex(Math.abs(hash) % 360, 72, 56);
}

export function objectColor(object: MapObject): string {
  return object.style.color ?? defaultObjectColor(object.exportId || object.id);
}

export function colorWithAlpha(color: string, alpha: string): string {
  return /^#[0-9a-f]{6}$/i.test(color) ? `${color}${alpha}` : color;
}
