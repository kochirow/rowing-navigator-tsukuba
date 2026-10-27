# 文書の案内

作成日: 2026-10-24

このリポジトリには100を超える文書がある。**いま有効な文書(正本)** と、
**その時点の判断を残した記録** を分けて読むこと。記録は、書かれた日より後の変更を反映していない。

## 読む順番(初めての人)

1. [../README.md](../README.md) — アプリの概要、セットアップ、使い方
2. [DESIGN_PRINCIPLES.md](DESIGN_PRINCIPLES.md) — 運用前提と設計原則(第1・2章が**最上位の規範**)。第3章は設定値の根拠
3. [../CLAUDE.md](../CLAUDE.md) — 実装の地図(安全経路のファイルと役割)、警告の鳴り方、守るべき不変条件13項目
4. [../AGENTS.md](../AGENTS.md) — ブランチ・コミット・PR・マージ・Rules 反映の規約
5. [DESIGN.md](DESIGN.md) — 全体の構成、画面、データの置き場所

CLAUDE.md と AGENTS.md は AI エージェント向けに書いてあるが、人が作業するときも同じ規約に従う。

## 食い違いを見つけたら

優先の順番(2026-10-27 利用者決定。詳しくは [../CLAUDE.md](../CLAUDE.md)「設計原則」):

1. **最上位の規範**: DESIGN_PRINCIPLES.md の第1章(運用前提)・第2章(設計原則)と、CLAUDE.md の不変条件13項目。
   両者は同格。変える・緩めるときは利用者の判断を仰ぐ。
2. **いまの値・挙動**: コード。文書(DESIGN_PRINCIPLES 第3章の数値を含む)とずれていたら、
   **コードで確かめてから文書を直す**。文書のほうが古いことが多い(2026-10-23 利用者の方針)。
3. **運用**(Git・PR・Rules 反映・ストア): AGENTS.md。
4. 記録と正本が食い違ったら、正本が優先する。記録は直さない(当時の記録として残す)。

## 正本(いま有効な文書)

| 文書 | 中身 |
| --- | --- |
| [DESIGN_PRINCIPLES.md](DESIGN_PRINCIPLES.md) | 運用前提・設計原則(最上位)・設定値の根拠(値はコードが正) |
| [DESIGN.md](DESIGN.md) | 全体構成・画面・データの置き場所 |
| [ios_build.md](ios_build.md) | iOS の配布ビルド手順(Android の作業パスの注意も4章) |
| [review_guide/](review_guide/README.md) | レビュー・動作確認の手順(Claude Code と codex の共通) |
| [今後実装したい機能.md](今後実装したい機能.md) | 将来の機能の**唯一の**記録先。新しい案はここへ足す |
| [実機ログ保存場所.md](実機ログ保存場所.md) | 実機テストの診断ログの保存先と読み方 |
| [design_notes/2026-08-20_艇種別安全定数の根拠台帳.md](design_notes/2026-08-20_艇種別安全定数の根拠台帳.md) | 艇種別の停止距離・寸法の来歴(DESIGN_PRINCIPLES 3.2 から参照) |
| [design_notes/replay_lab_使い方.md](design_notes/replay_lab_使い方.md) | 実機ログを使った再生ツールの使い方 |
| [store/公開までの手順_2026-10-20.md](store/公開までの手順_2026-10-20.md) | 公開までに利用者がする操作(7月のチェックリストより優先) |
| [store/データ取扱い台帳.md](store/データ取扱い台帳.md) | 送信・保存するデータの一覧とストア申告の回答案 |
| [store/ストア掲載・審査資料案.md](store/ストア掲載・審査資料案.md) | ストア説明文・審査メモの案 |
| [store/プライバシーポリシー案.md](store/プライバシーポリシー案.md)・[store/サポートページ案.md](store/サポートページ案.md) | 公開用の文面。英語版(`Privacy Policy Draft.md`・`Support Page Draft.md`)は翻訳で、日本語版が正 |
| [../tool/obstacle-plotter/README.md](../tool/obstacle-plotter/README.md) | 危険区域の座標を描くツール |

危険区域データ(`assets/data/sakuragawa_obstacles.json`)・設定値(`lib/config/`)・Rules(`firestore.rules`・
`database.rules.json`)は、文書ではなくそれ自体が正本である。

## 記録(その時点の判断。現在の方針ではない)

| 場所 | 中身 |
| --- | --- |
| `docs/要件定義_*.md`・`docs/実装計画_*.md`・`docs/改善計画_*.md` | 機能ごとの要件・計画。書かれた日付の時点のもの |
| [design_notes/](design_notes/) | 設計の検討メモ(上の2件を除く) |
| [review/](review/)・[reviews/](reviews/)・[../safety_reviews/](../safety_reviews/) | 過去のレビュー報告。未解決の指摘を拾うときに読む |
| [work_logs/](work_logs/) | 危険区域データの更新作業の記録 |
| [公開ロードマップ_2026-07-19.md](公開ロードマップ_2026-07-19.md)・[設計ブラッシュアップ提案.md](設計ブラッシュアップ提案.md) | 7月時点の計画・提案 |
| [store/公開前チェックリスト_2026-07-20.md](store/公開前チェックリスト_2026-07-20.md)・[store/公開候補_実機試験記録.md](store/公開候補_実機試験記録.md)・[store/無料枠・可用性検証_2026-07-21.md](store/無料枠・可用性検証_2026-07-21.md) | 7月時点の公開準備の記録 |
| `../tool/prototypes/` | 画面の試作(アプリのコードではない) |
