import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/ui/glass.dart';

void main() {
  test('tab under the lens', () {
    expect(tabAt(0, 70, 5), 0);
    expect(tabAt(69.9, 70, 5), 0);
    expect(tabAt(70, 70, 5), 1);
    expect(tabAt(1000, 70, 5), 4);
    expect(tabAt(-5, 70, 5), 0);
  });

  testWidgets('dragging the lens across the bar switches tab on release', (t) async {
    var selected = 0;
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: Scaffold(
        bottomNavigationBar: StatefulBuilder(
          builder: (context, set) => GlassTabBar(
            items: const [
              (CupertinoIcons.dot_radiowaves_left_right, CupertinoIcons.dot_radiowaves_left_right, 'Radio'),
              (CupertinoIcons.phone, CupertinoIcons.phone_fill, 'Calls'),
              (CupertinoIcons.person_2, CupertinoIcons.person_2_fill, 'Contacts'),
              (CupertinoIcons.chat_bubble, CupertinoIcons.chat_bubble_fill, 'Messages'),
              (CupertinoIcons.gear, CupertinoIcons.gear_solid, 'Settings'),
            ],
            index: selected,
            onTap: (i) => set(() => selected = i),
          ),
        ),
      ),
    ));
    final from = t.getCenter(find.text('Radio'));
    final to = t.getCenter(find.text('Messages'));
    final g = await t.startGesture(from);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 10)!);
      await t.pump();
    }
    expect(selected, 0, reason: 'nothing switches while the lens is held');
    await g.up();
    await t.pumpAndSettle();
    expect(selected, 3);

    await t.tap(find.text('Calls'));
    await t.pumpAndSettle();
    expect(selected, 1, reason: 'tapping still works');
  });
}
