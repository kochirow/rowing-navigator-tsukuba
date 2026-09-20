---
name: full-app-review
description: 桜川アプリの動作確認・総合監査を行う。機能監査や全体レビューの依頼に使い、限定差分・文書レビューには適用しない。
---

# アプリレビュー(動くことの監査)

**手順の本体は [docs/review_guide/README.md](../../../docs/review_guide/README.md) にある。
まずそれを読み、そこに書かれた手順に従うこと。この SKILL.md は入口にすぎない。**

手順書をリポジトリ本体(`docs/` と `tool/`)へ置いているのは、**codex にも同じ手順で
レビューさせるため**である。`.claude/` の下に置くと codex から参照しにくい。
codex は `AGENTS.md`「レビューを依頼されたとき」から同じ文書へ入る。
**手順を変えるときは `docs/review_guide/` を直す。この SKILL.md には手順を書かない**
(2か所に書くと必ず食い違う)。

## 場所

| 何 | パス |
| --- | --- |
| 手順の本体(モード選択・共通ルール・重大度・完了条件) | `docs/review_guide/README.md` |
| 軽量版(壊れ方 F1〜F6) | `docs/review_guide/quick_review.md` |
| 総合版のパス割り(P00〜P17) | `docs/review_guide/full_review_passes.md` |
| 観点 A〜N | `docs/review_guide/viewpoints.md` |
| 検証手段(数値検算・replay・実機ログ・自己反証) | `docs/review_guide/verification.md` |
| 報告書テンプレート | `docs/review_guide/report_templates.md` |
| 機械チェック | `tool/review/smoke_check.sh` |
| 棚卸し | `tool/review/inventory.sh` |
| 衝突判定本体の安全レビュー(総合版 P05) | `.claude/skills/collision-safety-review/SKILL.md` |

## 開始と完了

依頼の対象・修正権限を確認し、README §1でモードと検証範囲を選ぶ。smoke checkを重複実行しない。パス数ではなく依頼された範囲の完了で終了を判断する。
