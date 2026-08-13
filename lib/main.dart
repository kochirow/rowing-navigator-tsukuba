import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/firebase_options.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:rowing_navigator/screens/app_entry_gate.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:rowing_navigator/widgets/app_state_views.dart';
import 'package:rowing_navigator/services/safety_defaults_migration_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SafetyDefaultsMigrationService().migrateIfNeeded();
  runApp(const ProviderScope(child: App()));
}

class FirebaseBootstrap extends StatefulWidget {
  final Future<void> Function()? initialize;
  final Future<void> Function()? activateAppCheck;
  final Widget? initializedChild;

  const FirebaseBootstrap({
    super.key,
    this.initialize,
    this.activateAppCheck,
    this.initializedChild,
  });

  @override
  State<FirebaseBootstrap> createState() => _FirebaseBootstrapState();
}

class _FirebaseBootstrapState extends State<FirebaseBootstrap> {
  static const _appCheckStartupTimeout = Duration(seconds: 3);
  static const _appCheckRetryDelays = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];

  late Future<void> _initialization;
  Future<void>? _appCheckActivationInFlight;
  Timer? _appCheckRetryTimer;
  var _appCheckRetryAttempt = 0;
  var _appCheckActivated = false;

  @override
  void initState() {
    super.initState();
    _initialization = _initialize();
  }

  Future<void> _initialize() async {
    final customInitializer = widget.initialize;
    if (customInitializer != null) {
      await customInitializer();
      if (widget.activateAppCheck != null) {
        await _activateAppCheckWithoutBlockingLocalUse();
      }
      return;
    }
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (!kIsWeb) {
      await _activateAppCheckWithoutBlockingLocalUse();
    }
  }

  Future<void> _activateConfiguredAppCheck() {
    final customActivator = widget.activateAppCheck;
    if (customActivator != null) return customActivator();
    return FirebaseAppCheck.instance.activate(
      androidProvider:
          kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
      appleProvider: kDebugMode
          ? AppleProvider.debug
          : AppleProvider.appAttestWithDeviceCheckFallback,
    );
  }

  /// App Checkの一時障害やattestation timeoutで、端末内マップ・固定区域・
  /// 記録まで起動不能にしない。Firebase自体の初期化失敗は従来どおり
  /// 明示エラーにし、App Checkだけをバックグラウンドで再試行する。
  Future<void> _activateAppCheckWithoutBlockingLocalUse() async {
    if (_appCheckActivated) return;
    final activation =
        _appCheckActivationInFlight ??= _activateConfiguredAppCheck();
    unawaited(
      activation.then<void>((_) {
        _appCheckActivated = true;
        _appCheckRetryAttempt = 0;
        _appCheckRetryTimer?.cancel();
      }, onError: (Object error, StackTrace stackTrace) {
        debugPrint(
            'App Check activation failed; retrying in background: $error');
      }).whenComplete(() {
        if (identical(_appCheckActivationInFlight, activation)) {
          _appCheckActivationInFlight = null;
        }
      }),
    );
    try {
      await activation.timeout(_appCheckStartupTimeout);
    } catch (error) {
      debugPrint('App Check startup is degraded: $error');
      _scheduleAppCheckRetry();
    }
  }

  void _scheduleAppCheckRetry() {
    if (_appCheckActivated || _appCheckRetryTimer?.isActive == true) return;
    final delayIndex =
        _appCheckRetryAttempt.clamp(0, _appCheckRetryDelays.length - 1).toInt();
    _appCheckRetryAttempt += 1;
    _appCheckRetryTimer = Timer(_appCheckRetryDelays[delayIndex], () {
      if (!mounted || _appCheckActivated) return;
      unawaited(_activateAppCheckWithoutBlockingLocalUse());
    });
  }

  void _retry() {
    final nextInitialization = _initialize();
    setState(() {
      _initialization = nextInitialization;
    });
  }

  @override
  void dispose() {
    _appCheckRetryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initialization,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: AppLoadingView(message: 'サービスを準備しています…'),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: SafeArea(
              child: AppErrorView(
                icon: Icons.cloud_off,
                title: 'サービスを開始できませんでした',
                message: '通信状態を確認して再試行してください。繰り返す場合はサポートへ連絡してください。',
                primaryLabel: '再試行',
                onPrimary: _retry,
              ),
            ),
          );
        }
        return widget.initializedChild ?? const AppEntryGate();
      },
    );
  }
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rowing Navigator',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // 練習は日の出前後と夕方に集中する。暗い水面から真っ白な設定画面へ
      // 移ると、戻ったときしばらく水面が見えない。OS設定へ追従させる。
      darkTheme: buildAppDarkTheme(),
      themeMode: ThemeMode.system,
      home: const FirebaseBootstrap(),
    );
  }
}
