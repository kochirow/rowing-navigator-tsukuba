import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/firebase_options.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:rowing_navigator/screens/area_setting_screen.dart';
import 'package:rowing_navigator/screens/home_map_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const ProviderScope(child: App()));
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rowing Navigator',
      theme: ThemeData(
        useMaterial3: false,
        // ======== Custom Color Scheme ========
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue), // ベースを青に設定
        primaryColor: const Color(0xFF095372),
        primaryColorLight: const Color(0xFF4D9CBF),
        primaryColorDark: const Color(0xFF002E4D),
        scaffoldBackgroundColor: const Color(0xFFE0E0E0),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF095372),
        ),
        // =====================================
      ),
      home: const HomeMapScreen(),
      // home: const AreaSettingScreen(),
    );
  }
}
