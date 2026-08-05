/// 共有する固定障害物校正が、どの同梱プリセットを基準にするかを示す。
///
/// 座標差分だけを別バージョンのプリセットへ適用すると危険なため、
/// アプリとFirestoreの双方でversionとSHA-256の完全一致を要求する。
const currentHazardProfileDataVersion = 10;
const currentHazardProfileSha256 =
    '962ed029ec2ba091e7d5cfd1fbc6cf98d5fe1dad7787dff11a7f68bfb978f3e5';
