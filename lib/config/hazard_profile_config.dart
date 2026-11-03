/// 共有する固定障害物校正が、どの同梱プリセットを基準にするかを示す。
///
/// 座標差分だけを別バージョンのプリセットへ適用すると危険なため、
/// アプリとFirestoreの双方でversionとSHA-256の完全一致を要求する。
const currentHazardProfileDataVersion = 12;
const currentHazardProfileSha256 =
    'dfa991f4c2c3f5c2365a359e7dc3227bb7e5f160bf5720cceef3088590703b7c';
