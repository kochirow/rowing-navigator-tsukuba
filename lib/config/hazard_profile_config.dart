/// 共有する固定障害物校正が、どの同梱プリセットを基準にするかを示す。
///
/// 座標差分だけを別バージョンのプリセットへ適用すると危険なため、
/// アプリとFirestoreの双方でversionとSHA-256の完全一致を要求する。
const currentHazardProfileDataVersion = 8;
const currentHazardProfileSha256 =
    'b0f35c465695d70fb6dc7f7985b9622b2aa10ab742d7bfa2a43c028dcbd403dc';
