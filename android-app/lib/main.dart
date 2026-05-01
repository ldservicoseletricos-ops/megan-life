import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const MeganLifeApp()); }

class MeganLifeApp extends StatelessWidget {
  const MeganLifeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Megan Life',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C3AED), brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF080A12),
    ),
    home: const HomeScreen(),
  );
}
