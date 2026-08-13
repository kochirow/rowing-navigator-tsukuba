/// 公開ビルドで表示する連絡先。
///
/// Dart defineを渡した場合だけ差し替えられる。既定値にも公開済みURLを置き、
/// define漏れで審査用ビルドのリンクが無効にならないようにする。
const privacyPolicyUrl = String.fromEnvironment(
  'PRIVACY_POLICY_URL',
  defaultValue:
      'https://shore-factory-d8c.notion.site/Rowing-Navigator-Privacy-Policy-3a443cda3ff680539436ce17184c0202',
);
const supportUrl = String.fromEnvironment(
  'SUPPORT_URL',
  defaultValue:
      'https://shore-factory-d8c.notion.site/Rowing-Navigator-Support-3a443cda3ff680cca1ecf4d8c44512a5',
);

/// 問題のある利用・不適切な危険情報・問い合わせを受け付ける唯一の窓口。
/// チーム内チャットや通報データを新設せず、運営がGoogle Formで受け取る。
const supportReportFormUrl = 'https://forms.gle/Cj2jL3rtUwfQH9YP7';

/// チーム作成・参加時に同意を記録する利用規約の世代。
/// 内容を変えたときだけ更新する。既存メンバーへ遡及強制はしない。
const teamTermsVersion = '2026-08-03';
