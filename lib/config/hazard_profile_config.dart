/// 共有する固定障害物校正が、どの同梱プリセットを基準にするかを示す。
///
/// 座標差分だけを別バージョンのプリセットへ適用すると危険なため、
/// アプリとFirestoreの双方でversionとSHA-256の完全一致を要求する。
const currentHazardProfileDataVersion = 9;
const currentHazardProfileSha256 =
    'aaafbf67b64c5b50aa401c77d849f52b1db4fe2a5bc122e5b09bc989d3572b33';
