import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/screens/settings_screen.dart';

void main() {
  for (final b in Brightness.values) {
    testWidgets('credit link keeps the text colour ($b)', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: b),
        home: const Scaffold(body: Credit(role: 'Creator', name: 'ysamouhos', github: 'ysamouhos')),
      ));
      final link = t.widget<Text>(find.text('github.com/ysamouhos'));
      final onSurface = ThemeData(brightness: b).colorScheme.onSurface;
      expect(link.style?.color, onSurface);
      expect(link.style?.decoration, TextDecoration.underline);
      expect(find.text('ysamouhos'), findsOneWidget);
      expect(find.text('CREATOR'), findsOneWidget);
    });
  }
}
