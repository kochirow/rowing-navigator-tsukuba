---
name: full-app-review
description: 桜川アプリ(rowing_navigator)を「現場で機能が動くか」の観点で監査するレビューskill。警告が鳴るべき場面で鳴るか、位置共有が止まらないか、他艇が画面と評価から消えないか、航行が途中で止まらないかを、症状(壊れ方)から辿る軽量版(F1〜F6・1〜2セッション)と、実装全体を複数パスで網羅する総合版(P00〜P17)の2モードを持つ。ユーザーが「動作確認レビュー」「ちゃんと動くか見て」「リリース前の点検」「実機テスト前の確認」「総合レビュー」「全体レビュー」に類することを口にしたとき、大きな機能追加の後、ストア提出前に使う。衝突判定本体だけを深く見るのは collision-safety-review skill の役割であり、総合版は P05 でそれを呼び出す。差分レビュー(/code-review)ではなくワーキングツリー全体が対象。
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

## 最初にやること

```bash
bash tool/review/smoke_check.sh
```

引数なしでよい(いまの状態が CI に担保されているかを見て、解析とテストを流すかを自動判定する)。
続けて `docs/review_guide/README.md` §1 でモードを選ぶ。迷ったら軽量版。
