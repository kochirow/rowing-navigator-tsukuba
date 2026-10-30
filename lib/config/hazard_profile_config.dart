/// 共有する固定障害物校正が、どの同梱プリセットを基準にするかを示す。
///
/// 座標差分だけを別バージョンのプリセットへ適用すると危険なため、
/// アプリとFirestoreの双方でversionとSHA-256の完全一致を要求する。
const currentHazardProfileDataVersion = 11;
const currentHazardProfileSha256 =
    '5bef0edfe2785b357cc2be4014a610430900526c9363e7474b637f102de9e413';
