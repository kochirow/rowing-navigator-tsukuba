# Design Document

## Overview

Rowing Navigator のアーキテクチャ設計書です。

## Used technologies

// サービス・ライブラリとか、バージョンも添えて

<!--
## System architecture

大域的なシステム構成

## Directory structure

ファイルや言葉の定義など
 -->

 <!-- | Collection       | Document            | Field     | Type            | Description                |
| ---------------- | ------------------- | --------- | --------------- | -------------------------- |
| messages         | boatId（string）    | boatId    | string          | 艇の識別子                 |
|                  |                     | boatType  | string          | 艇種 e.g. r_1x, r_4x, etc. |
|                  |                     | lat       | number          | 緯度                       |
|                  |                     | lng       | number          | 経度                       |
|                  |                     | heading   | number          | 方位角（度）               |
|                  |                     | speed     | number          | 速度（m/s）                |
|                  |                     | timestamp | timestamp       | タイムスタンプ             |
| static_obstacles | auto-generated | points    | array<geopoint> | 静的障害物領域の座標点配列 | -->

## References

- [Flutter x Firebase で位置情報共有アプリを作ろう](https://zenn.dev/heyhey1028/books/flutter-firebase-handson)
