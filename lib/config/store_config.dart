/// ストア配布ビルドで必ず上書きする公開情報。
///
/// 例:
/// `--dart-define=PRIVACY_POLICY_URL=https://example.org/privacy`
/// `--dart-define=SUPPORT_URL=https://example.org/support`
const privacyPolicyUrl = String.fromEnvironment('PRIVACY_POLICY_URL');
const supportUrl = String.fromEnvironment('SUPPORT_URL');
