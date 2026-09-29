import 'package:flutter/material.dart';

import 'connect_page.dart';

void main() {
  runApp(const MacConnectApp());
}

class MacConnectApp extends StatelessWidget {
  const MacConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFFF3F1EA);
    const paper = Color(0xFF121416);
    const card = Color(0xFF1C1F24);
    const accent = Color(0xFF8EB7FF);
    return MaterialApp(
      title: 'MacConnect',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: paper,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          onPrimary: Color(0xFF102033),
          surface: card,
          onSurface: ink,
          error: Color(0xFFFFB4AB),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: paper,
          foregroundColor: ink,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: card,
          margin: EdgeInsets.zero,
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return const Color(0xFF102033);
              return ink;
            }),
          ),
        ),
      ),
      home: const ConnectPage(),
    );
  }
}
