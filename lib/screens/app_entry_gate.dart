import 'dart:async';

import 'package:flutter/material.dart';

import '../models/team_model.dart';
import '../services/team_service.dart';
import '../widgets/app_state_views.dart';
import 'home_map_screen.dart';
import 'team_onboarding_screen.dart';

/// Firebase初期化後に、匿名アカウントのチーム所属を1回だけ復元する。
///
/// 参加済みならログイン画面は出さずマップへ、未参加なら
/// チーム作成/招待コードの二択へ進める。
class AppEntryGate extends StatefulWidget {
  final TeamService? teamService;

  const AppEntryGate({super.key, this.teamService});

  @override
  State<AppEntryGate> createState() => _AppEntryGateState();
}

class _AppEntryGateState extends State<AppEntryGate> {
  late final TeamService _teamService = widget.teamService ?? TeamService();
  late Future<TeamMembership?> _membership;
  StreamSubscription<String?>? _authenticationSubscription;
  String? _observedUserId;

  @override
  void initState() {
    super.initState();
    _observedUserId = _teamService.currentUserId;
    _membership = _teamService.restoreMembership();
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
    super.dispose();
  }

  void _retry() {
    setState(() {
      _membership = _teamService.restoreMembership();
    });
  }

  void _openMap(TeamMembership membership) {
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
        return const HomeMapScreen();
      },
    );
  }
}
