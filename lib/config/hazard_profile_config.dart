/// 共有する固定障害物校正が、どの同梱プリセットを基準にするかを示す。
///
/// 座標差分だけを別バージョンのプリセットへ適用すると危険なため、
/// アプリとFirestoreの双方でversionとSHA-256の完全一致を要求する。
const currentHazardProfileDataVersion = 5;
const currentHazardProfileSha256 =
    '15631cf1f94d0edf9c7608b85e16e7d29961a2fcc5d7c47c11976ac0988991da';
