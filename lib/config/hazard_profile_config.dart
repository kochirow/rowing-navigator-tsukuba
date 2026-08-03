/// 共有する固定障害物校正が、どの同梱プリセットを基準にするかを示す。
///
/// 座標差分だけを別バージョンのプリセットへ適用すると危険なため、
/// アプリとFirestoreの双方でversionとSHA-256の完全一致を要求する。
const currentHazardProfileDataVersion = 8;
const currentHazardProfileSha256 =
    'b94e6f0afb23d153f50f63d8f43e020d62cb61fe8cbbe38777822a8e8671ed88';
