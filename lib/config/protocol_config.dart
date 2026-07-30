/// 他艇位置共有プロトコルの互換性境界。
///
/// protocol/app/profileの版は診断・ログ用のメタデータであり、
/// 版の不一致だけで他艇の位置を破棄しない。受信側は自分が理解できる
/// 共通フィールドを使い、未知の任意フィールドは無視する。
///
/// appVersionはストアのbuild番号を含めないプロダクト版とする。
/// 同じ通信仕様の差し戻し再申請(+2, +3...)で互換性を壊さない。
const currentPositionProtocolVersion = 1;
const currentPositionAppVersion = '1.0.0';
const currentHazardProfileVersion = 'sakuragawa-v3';

/// 現行アプリが自身で生成する版。受信の拒否リストではない。
const supportedPositionProtocolVersions = {currentPositionProtocolVersion};
const supportedHazardProfileVersions = {currentHazardProfileVersion};
