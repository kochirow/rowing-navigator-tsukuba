// # 練習ログの自動回収の設定値
//
// 航行・監視を終えたら、診断ZIPを開発者の Google ドライブへ自動で送る。
// 受け口は Google Apps Script(tool/gas/log_upload/Code.gs)。
// 表示と回収だけに使う。安全経路(判定・提示)には何も戻さない。
// 方式の比較と決定: docs/実装計画_2026-11-10_ログの自動回収.md

/// 受け口(Apps Script のウェブアプリ)の URL。空なら自動回収はしない。
///
/// 前提: URL を知っていても、Firebase のログインとチームのメンバーかを
/// 受け口が確かめるので、送れるのはチームのメンバーだけ(2026-11-10 利用者決定)。
/// URL を変えたら、新しい版を配布するまで古い版は古い URL へ送る。
const String autoLogUploadEndpoint =
    'https://script.google.com/macros/s/AKfycbzKGzZuo9N9DwTYkx5wpHMMc-VXwybArrdZ1ap-dNFRL6H6MxwKs09tzZWfyZdMt-q5jA/exec';

/// 自動で送る航行・監視の長さの下限 [秒]。
///
/// 前提: 桟橋での試し起動や、起動してすぐ閉じた記録は解析に使えない。
/// 5分あれば警告の場面が1つは入りうる(2026-11-10 利用者決定)。
/// 「まとめて送る」の下限(15分・2km、log_export_config.dart)より短くし、
/// 短い練習で鳴った警告も集める。長さは記録の始まりから終わりまでで数える。
const double autoLogUploadMinDurationSec = 5 * 60;

/// 送れなかったときに、次に試すまでの待ち時間。
///
/// 前提: 桟橋や艇庫は電波が弱く、数分で戻ることが多い。何度も失敗するときは
/// 電池と通信を使い続けないよう、間を空ける。最後の値を繰り返す。
/// アプリを前面に戻したときと次の起動でも試す。
const List<Duration> autoLogUploadRetryDelays = [
  Duration(minutes: 1),
  Duration(minutes: 5),
  Duration(minutes: 15),
  Duration(hours: 1),
];

/// 1回の送信を待つ上限。
///
/// 前提: 1練習の診断ZIPは実測 0.1〜1.2MB(2026-08〜11 の実機ログ)。
/// 弱い電波で 1MB を送っても1分あれば足りる。受け口が遅いときに
/// 次の記録の送信が止まり続けないよう区切る。
const Duration autoLogUploadRequestTimeout = Duration(seconds: 90);
