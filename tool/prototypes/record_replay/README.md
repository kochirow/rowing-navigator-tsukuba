# 練習記録リプレイ 試作（HTML）

2026-09-24 に利用者と操作しながら仕様を固めた、記録画面の試作。
**アプリのコードではない。** 実装時に挙動と見た目を確かめる参照物として残す。
仕様の正本は [docs/design_notes/2026-09-24_練習記録リプレイ_全面再設計.md](../../../docs/design_notes/2026-09-24_練習記録リプレイ_全面再設計.md)、
実装の手順は [docs/実装計画_2026-09-24_練習記録リプレイ.md](../../../docs/実装計画_2026-09-24_練習記録リプレイ.md)。

## 開き方

```bash
python3 tool/prototypes/record_replay/build_data.py <実機テストログデータのフォルダ>
python3 -m http.server 8765 --directory tool/prototypes/record_replay
```

ブラウザで `http://localhost:8765/` を開き、表示幅をスマホ（375px）にする。

- `data.js` には実機ログの航跡（位置）が入るので **Git に入れない**（`.gitignore` 済み）。
- 地図タイルは Esri World Gray Canvas / 国土地理院。アプリでは Google Maps を使う。

## speed_eval/

艇速推定（設計書 §6.5）の検証スクリプト。8/6 の8+に同乗した2台の推定の一致で方式を比べる。

```bash
cd tool/prototypes/record_replay/speed_eval && python3 eval8.py <実機テストログデータのフォルダ>
```
