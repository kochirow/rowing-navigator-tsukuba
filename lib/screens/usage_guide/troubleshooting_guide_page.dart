import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/alert_presentation_config.dart';
import '../../config/ashore_config.dart';
import '../../config/coach_config.dart';
import '../../config/risk_evaluator_config.dart' as risk_config;
import '../../config/store_config.dart';
import '../../theme/app_theme.dart';
import 'guide_widgets.dart';

/// 故障かな？と思ったら。
///
/// 載せるのは「故障に見えるが仕様」の挙動と、端末の設定を直す必要がある
/// 挙動だけ。仕様上の静音や表示のみの挙動を知らないと「鳴らない＝壊れた」と
/// 判断され、使われなくなる(DESIGN_PRINCIPLES 原則4と同じ結果になる)。
///
/// 見出しは利用者が口にする症状にし、仕組みの名前(低速静音・陸上判定)は使わない。
/// 秒数・速度は設定値から出す。設定を変えたときに説明だけが古くならないように。
class TroubleshootingGuidePage extends StatelessWidget {
  const TroubleshootingGuidePage({super.key});

  static const title = '故障かな？と思ったら';

  /// 1.667m/s → "分速100m"。
  static String get lowSpeedText =>
      '分速${(lowSpeedAudioMuteSpeedMetersPerSecond * 60).round()}m';

  /// 180秒 → "3分"、90秒 → "90秒"。
  static String _duration(int seconds) =>
      seconds >= 120 && seconds % 60 == 0 ? '${seconds ~/ 60}分' : '$seconds秒';

  Future<void> _open(BuildContext context, String value) async {
    final uri = Uri.tryParse(value);
    final messenger = ScaffoldMessenger.of(context);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('URLを開けませんでした。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    final ashoreSeconds = ashoreConfirmationDuration.inSeconds;

    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: ListView(
        padding: EdgeInsets.all(dimens.space4),
        children: [
          GuideTroubleItem(
            symptom: '止まっている・ゆっくり進んでいると、橋や岸の音が鳴らない',
            reason: '$lowSpeedTextより遅い間は、橋・橋脚・岸・逆走の音を止めています。'
                '止まっている間は、ほかの固定の危険区域の音も止めます。'
                '休憩中やコーチの指示を聞いている間に鳴らないようにするためです。'
                '画面の表示は続き、他の艇の警告は止めません。',
            action: '故障ではありません。漕ぎ出せば戻ります。',
          ),
          GuideTroubleItem(
            symptom: '陸に上がったら音が止まった',
            reason: '岸より陸側に$ashoreSeconds秒いると、音だけ止めて画面上部に帯を出します。'
                '水面に戻れば自動で戻ります。',
            action: '故障ではありません。水上なのに帯が出ているときは「音を戻す」を押してください。',
          ),
          const GuideTroubleItem(
            symptom: '岸の近くを走っても鳴らない',
            reason: '川幅が狭く岸はいつも近いので、近いだけでは鳴らしません。'
                'このまま進むと岸に当たる見込みが出たときに鳴ります。',
            action: '故障ではありません。',
          ),
          const GuideTroubleItem(
            symptom: '画面上部に「GPS」「受信」が出たのに音が鳴らない',
            reason: '測位や通信の不調は画面の表示だけで知らせ、音にはしません。'
                '読み上げると、本当に鳴るべき衝突の警告と重なるためです。',
            action: '空が開けた場所へ出て、通信を確かめてください。'
                'メニューの「端末とデータ」で状態を見られます。',
          ),
          GuideTroubleItem(
            symptom: '他の艇が地図に出ない',
            reason: '同じチームに入っていない、相手が「航行スタート」を押していない、'
                '通信が切れている、のいずれかです。'
                '更新が途絶えた艇は${risk_config.boatStaleTimeoutSeconds}秒で地図から消えます。',
            action: '相手のチーム名を確かめてください。画面上部に「受信」が出ていないかも見てください。',
          ),
          const GuideTroubleItem(
            symptom: '警告が鳴ったのに、画面の縁が全体で光って向きが分からない',
            reason: '回頭中や低速時は艇の向きが確かでないので、向きを出さずに縁の全体を光らせます。'
                '間違った側を振り向かせないためです。',
            action: '故障ではありません。周りを見回してください。',
          ),
          const GuideTroubleItem(
            symptom: '音がまったく出ない',
            reason: '端末の音量・消音モード・Bluetooth の接続先のいずれかが原因のことが多いです。',
            action: '使い方の「地図と警告音」にある「警告音の試聴」で、音が出るか確かめてください。',
          ),
          const GuideTroubleItem(
            symptom: '監視中に画面が消える',
            reason: '監視中は画面を点けたままにしません。陸では手で点け直せるので、電池を優先しています。'
                '画面が消えても記録は続きます。航行中は点けたままにします。',
            action: '故障ではありません。',
          ),
          GuideTroubleItem(
            symptom: '監視中、止まっている艇がいても音が鳴らない',
            reason: '監視中の異常(${_duration(stoppedAlertSec)}動いていない・'
                '${_duration(lostAlertSec)}更新がない)は、地図上の件数と艇一覧で知らせ、'
                '音は鳴らしません。トランシーバーの音声と重なるためです。',
            action: '地図上の件数の表示を押すと、艇一覧が開きます。',
          ),
          const GuideTroubleItem(
            symptom: 'チームに入れなくなった',
            reason: '端末の認証情報が消えたときに起きます。'
                'アプリを再インストールすると、元に戻せなくなることがあります。',
            action: '再インストールはせず、招待コードでもう一度参加してください。',
          ),
          SizedBox(height: dimens.space3),
          GuideSection(
            title: '解決しないとき',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (supportUrl.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _open(context, supportUrl),
                    icon: const Icon(Icons.help_outline),
                    label: const Text('サポート'),
                  ),
                SizedBox(height: dimens.space2),
                OutlinedButton.icon(
                  onPressed: () => _open(context, supportReportFormUrl),
                  icon: const Icon(Icons.mail_outline),
                  label: const Text('通報・お問い合わせ'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
