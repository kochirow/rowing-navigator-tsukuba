import 'dart:async';

import 'package:flutter/material.dart';

import '../models/team_model.dart';
import '../services/account_display_name_service.dart';
import '../services/team_service.dart';
import '../widgets/app_state_views.dart';
import 'display_name_registration_screen.dart';
import 'home_map_screen.dart';
import 'team_onboarding_screen.dart';

/// Firebase初期化後に、匿名アカウントのチーム所属を1回だけ復元する。
///
/// 参加済みならログイン画面は出さずマップへ、未参加なら
/// チーム作成/招待コードの二択へ進める。名前が未登録なら、
/// マップの前に名前の登録画面を挟む。
class AppEntryGate extends StatefulWidget {
  final TeamService? teamService;
  final AccountDisplayNameService? displayNameService;

  /// 所属と名前が揃ったあとに出す画面。既定はマップ(テスト用に差し替える)。
  final WidgetBuilder? homeBuilder;

  const AppEntryGate({
    super.key,
    this.teamService,
    this.displayNameService,
    this.homeBuilder,
  });

  @override
  State<AppEntryGate> createState() => _AppEntryGateState();
}

class _AppEntryGateState extends State<AppEntryGate> {
  late final TeamService _teamService = widget.teamService ?? TeamService();
  late final AccountDisplayNameService _displayNameService =
      widget.displayNameService ?? AccountDisplayNameService();
  late Future<TeamMembership?> _membership;
  StreamSubscription<String?>? _authenticationSubscription;
  StreamSubscription<bool>? _membershipSubscription;
  String? _observedUserId;

  @override
  void initState() {
    super.initState();
    _observedUserId = _teamService.currentUserId;
    _membership = _restoreAndWatchMembership();
    _authenticationSubscription =
        _teamService.authenticationUserIds.listen(_handleAuthenticationChange);
  }

  void _handleAuthenticationChange(String? userId) {
    final previousUserId = _observedUserId;
    if (previousUserId == userId) return;
    _observedUserId = userId;

    // 初回参加の null -> 新UID はonCompletedで処理する。参加後の
    // UID消失/置換だけを検知し、勝手に別の匿名UIDを作らず再参加へ戻す。
    if (previousUserId != null && mounted) _retry();
  }

  @override
  void dispose() {
    _authenticationSubscription?.cancel();
    _membershipSubscription?.cancel();
    super.dispose();
  }

  Future<TeamMembership?> _restoreAndWatchMembership() async {
    final membership = await _teamService.restoreMembership();
    if (membership != null) _watchMembership(membership.userId);
    return membership;
  }

  void _watchMembership(String userId) {
    _membershipSubscription?.cancel();
    _membershipSubscription = _teamService.watchMembershipExists(userId).listen(
      (exists) {
        if (!exists && mounted) _retry();
      },
      // 圏外や一時的なApp Check/Rules障害では、既存の復元方針どおり
      // ローカル機能を直ちに終了させず、次のサーバー状態を待つ。
      onError: (_, __) {},
    );
  }

  void _retry() {
    setState(() {
      _membership = _restoreAndWatchMembership();
    });
  }

  void _openMap(TeamMembership membership) {
    _watchMembership(membership.userId);
    setState(() {
      _membership = Future<TeamMembership?>.value(membership);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TeamMembership?>(
      future: _membership,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: AppLoadingView(message: 'チーム情報を確認しています…'),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: SafeArea(
              child: AppErrorView(
                icon: Icons.cloud_off,
                title: 'チーム情報を確認できませんでした',
                message: '通信状態を確認して再試行してください。チームに参加済みの場合、アプリの再インストールはしないでください。',
                primaryLabel: '再試行',
                onPrimary: _retry,
              ),
            ),
          );
        }
        final membership = snapshot.data;
        if (membership == null) {
          return TeamOnboardingScreen(
            teamService: _teamService,
            recoveryHint: TeamService.recoveryHint,
            onCompleted: _openMap,
          );
        }
        return AccountNameGate(
          key: ValueKey(membership.userId),
          membership: membership,
          service: _displayNameService,
          publish: _teamService.updateMyDisplayName,
          homeBuilder: widget.homeBuilder ?? (_) => const HomeMapScreen(),
        );
      },
    );
  }
}

/// 名前が決まるまでマップの代わりに登録画面を出す。
///
/// 判定は端末内の値だけで行い、通信を待たない(原則1)。メンバー情報への
/// 写しは裏で送り、失敗しても次の起動で送り直す。
class AccountNameGate extends StatefulWidget {
  final TeamMembership membership;
  final AccountDisplayNameService service;
  final Future<void> Function(String name) publish;
  final WidgetBuilder homeBuilder;

  const AccountNameGate({
    super.key,
    required this.membership,
    required this.service,
    required this.publish,
    required this.homeBuilder,
  });

  @override
  State<AccountNameGate> createState() => _AccountNameGateState();
}

class _AccountNameGateState extends State<AccountNameGate> {
  late Future<_NameState> _state = _load();
  String? _name;

  Future<_NameState> _load() async {
    try {
      final name = await widget.service
          .resolve(serverName: widget.membership.displayName);
      if (name != null) {
        _name = name;
        _publishInBackground();
        return const _NameState.registered();
      }
      return _NameState.unregistered(await widget.service.suggestion());
    } catch (error) {
      // 端末内の設定を読めない。名前の登録で航行を止めないよう、地図へ進む
      // (航行開始の画面で名前を入れられる)。
      debugPrint('Failed to load account display name: $error');
      return const _NameState.registered();
    }
  }

  void _publishInBackground() {
    unawaited(widget.service.publishIfNeeded(
      userId: widget.membership.userId,
      serverName: widget.membership.displayName,
      publish: widget.publish,
    ));
  }

  void _handleSaved(String name) {
    _name = name;
    _publishInBackground();
    setState(() {
      _state = Future.value(const _NameState.registered());
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_NameState>(
      future: _state,
      builder: (context, snapshot) {
        final state = snapshot.data;
        if (state == null) {
          return const Scaffold(
            body: AppLoadingView(message: '名前を確認しています…'),
          );
        }
        if (!state.registered && _name == null) {
          return DisplayNameRegistrationScreen(
            service: widget.service,
            initialName: state.suggestion,
            onSaved: _handleSaved,
          );
        }
        return widget.homeBuilder(context);
      },
    );
  }
}

class _NameState {
  final bool registered;
  final String? suggestion;

  const _NameState.registered()
      : registered = true,
        suggestion = null;

  const _NameState.unregistered(this.suggestion) : registered = false;
}
