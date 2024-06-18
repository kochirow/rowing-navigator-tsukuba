import 'package:flutter/material.dart';
import 'package:rowing_navigator/firebase_options.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:rowing_navigator/screens/home_map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Future<void> main() async {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rowing Navigator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeMapScreen(),
    );
  }
}
