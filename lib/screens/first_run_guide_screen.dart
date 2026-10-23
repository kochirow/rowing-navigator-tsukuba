import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../config/risk_evaluator_config.dart' as risk_config;
import '../config/warning_audio_config.dart';
import '../services/first_run_guide_store.dart';
import '../theme/app_theme.dart';
import 'usage_guide/guide_widgets.dart';

/// 初めて使う端末にだけ、案内を1回出す。
///
/// [ready] は「地図の準備が済み、待機中」のとき true にする。航行中・監視中には
/// 重ねない。表示した時点で表示済みにし、スキップされても二度と自動では出さない
/// (使い方のトップからは開ける)。フラグの読み書きに失敗したら出さない。
/// 案内は航行・監視の条件にしない(不変条件5)。
///
/// 地図画面が巨大なので、判断と遷移をここへ切り出している。
void useFirstRunGuide(
  BuildContext context, {
  required bool ready,
  required double primaryWarningLeadSeconds,
  required double advanceWarningLeadSeconds,
  FirstRunGuideStore store = const FirstRunGuideStore(),
}) {
  final checked = useRef(false);
  useEffect(() {
    if (!ready || checked.value) return null;
    checked.value = true;
    var disposed = false;
    unawaited(() async {
      if (!await store.shouldShow() || disposed || !context.mounted) return;
      await store.markSeen();
      if (disposed || !context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => FirstRunGuideScreen(
            primaryWarningLeadSeconds: primaryWarningLeadSeconds,
            advanceWarningLeadSeconds: advanceWarningLeadSeconds,
          ),
        ),
      );
    }());
    return () => disposed = true;
  }, [ready]);
}

/// 初めて使う人への案内(4枚)。
///
/// 型は Material Design の Self-select(最初に役割を選ばせ、その後を分ける)。
/// 漕ぐ人と陸で見る人ではやることがまったく違うため。利点を並べる
/// カルーセルは作らない(Self-select と組み合わせない、という指針に従う)。
///
/// - どの画面からでも「スキップ」できる。案内を読むことを航行・監視の
///   条件にしない(不変条件5、原則1・2)。
/// - 役割の選択は3枚目の中身を変えるだけで、記憶もしないし機能も制限しない。
/// - バックグラウンド位置情報の説明はここへ移さない。許可を求める直前
///   (航行スタート時)に説明する必要があるため。
class FirstRunGuideScreen extends StatefulWidget {
  const FirstRunGuideScreen({
    super.key,
    this.primaryWarningLeadSeconds = risk_config.primaryWarningLeadSeconds,
    this.advanceWarningLeadSeconds = risk_config.advanceWarningLeadSeconds,
  });

  final double primaryWarningLeadSeconds;
  final double advanceWarningLeadSeconds;

  @override
  State<FirstRunGuideScreen> createState() => _FirstRunGuideScreenState();
}

enum _Role { navigate, watch }

class _FirstRunGuideScreenState extends State<FirstRunGuideScreen> {
  static const _pageCount = 4;

  final _controller = PageController();
  int _page = 0;
  _Role? _role;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  void _next() {
    if (_page >= _pageCount - 1) {
      _close();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _chooseRole(_Role role) {
    setState(() => _role = role);
    _next();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final isLast = _page == _pageCount - 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.all(dimens.space2),
                child: isLast
                    ? const SizedBox(height: 48)
                    : TextButton(onPressed: _close, child: const Text('スキップ')),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (page) => setState(() => _page = page),
                children: [
                  _introPage(context),
                  _rolePage(context),
                  _firstStepsPage(context),
                  _alertsPage(context),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.all(dimens.space4),
              child: Row(
                children: [
                  for (var i = 0; i < _pageCount; i++)
                    Container(
                      width: 8,
                      height: 8,
                      margin: EdgeInsets.only(right: dimens.space1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            i == _page ? colors.primary : colors.textDisabled,
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(120, 48),
                    ),
                    child: Text(isLast ? 'はじめる' : '次へ'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageBody(BuildContext context, String title, List<Widget> children) {
    final colors = context.colors;
    final dimens = context.dimens;
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: dimens.space4),
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: colors.textPrimary,
          ),
        ),
        SizedBox(height: dimens.space4),
        ...children,
      ],
    );
  }

  Widget _introPage(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return _pageBody(context, 'Rowing Navigator', [
      Text(
        '同じチームで位置を共有している艇と、登録済みの危険区域に近づくと、'
        '音声で知らせます。',
        style: TextStyle(fontSize: 17, color: colors.textPrimary, height: 1.5),
      ),
      SizedBox(height: dimens.space4),
      const GuideLimitsNotice(),
    ]);
  }

  Widget _rolePage(BuildContext context) {
    final dimens = context.dimens;
    return _pageBody(context, 'どちらで使いますか', [
      _RoleCard(
        icon: Icons.rowing,
        title: '航行する',
        subtitle: '艇に乗って漕ぐ',
        selected: _role == _Role.navigate,
        onTap: () => _chooseRole(_Role.navigate),
      ),
      SizedBox(height: dimens.space3),
      _RoleCard(
        icon: Icons.visibility_outlined,
        title: '監視する',
        subtitle: '陸から全艇を見る',
        selected: _role == _Role.watch,
        onTap: () => _chooseRole(_Role.watch),
      ),
      SizedBox(height: dimens.space3),
      Text(
        'あとからどちらでも使えます。',
        style: TextStyle(fontSize: 13, color: context.colors.textSecondary),
      ),
    ]);
  }

  Widget _firstStepsPage(BuildContext context) {
    final dimens = context.dimens;
    const navigateSteps = GuideSteps(
      steps: [
        '端末を艇に固定します。航行中は画面に触れなくても使えます。',
        '音量を上げ、消音モードを切ります。',
        '地図の下の「航行スタート」を押します。',
      ],
    );
    const watchSteps = GuideSteps(
      steps: [
        '地図の下の「監視スタート」を押します。',
        '航行中の全艇の位置と航跡が出ます。',
        '記録は自動で端末に残ります。',
      ],
    );
    return switch (_role) {
      _Role.navigate => _pageBody(context, '航行するとき', const [navigateSteps]),
      _Role.watch => _pageBody(context, '監視するとき', const [watchSteps]),
      null => _pageBody(context, '最初にすること', [
          const GuideSection(title: '航行するとき', child: navigateSteps),
          SizedBox(height: dimens.space1),
          const GuideSection(title: '監視するとき', child: watchSteps),
        ]),
    };
  }

  Widget _alertsPage(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final primary = formatGuideSeconds(widget.primaryWarningLeadSeconds);
    final advance = formatGuideSeconds(widget.advanceWarningLeadSeconds);
    return _pageBody(context, '警告は音で聞く', [
      GuideUrgencyRow(
        icon: Icons.graphic_eq,
        title: '鳴る',
        body: 'あと$advance秒以内に届きます。届かなくなるまで繰り返します。',
      ),
      GuideUrgencyRow(
        icon: Icons.blur_on,
        title: '不確かなとき',
        body: 'あと$primary秒以内になってから鳴らします。',
      ),
      const GuideUrgencyRow(
        icon: Icons.visibility_outlined,
        title: '表示のみ',
        body: '近くにありますが、届く見込みはありません。',
      ),
      Text(
        '航行画面では、相手のいる側の画面の縁が赤く点滅します。',
        style: TextStyle(color: colors.textPrimary),
      ),
      SizedBox(height: dimens.space4),
      const GuideAudioPreviewList(
        entries: [(otherBoatWarningAudioAsset, '他艇')],
      ),
      SizedBox(height: dimens.space2),
      Text(
        '詳しい説明は、メニューの「使い方」にあります。',
        style: TextStyle(fontSize: 13, color: colors.textSecondary),
      ),
    ]);
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Material(
      color: colors.card,
      shape: RoundedRectangleBorder(
        borderRadius: dimens.borderMd,
        side: BorderSide(
          color: selected ? colors.primary : colors.textDisabled,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: dimens.borderMd,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(dimens.space4),
          child: Row(
            children: [
              Icon(icon, size: 36, color: colors.primary),
              SizedBox(width: dimens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: colors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
