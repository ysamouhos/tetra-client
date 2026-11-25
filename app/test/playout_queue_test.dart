import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/services/audio_io.dart';

void main() {
  late DateTime now;
  late PlayoutQueue q;
  setUp(() {
    now = DateTime(2026, 11, 25, 12);
    q = PlayoutQueue(8000, clock: () => now);
  });

  test('empty queue asks for a block of silence right away', () {
    expect(q.queuedSamples(), 0);
    expect(q.silenceToFeed(), 2000);
  });

  test('fed audio drains in real time and is topped up before it runs dry', () {
    q.fed(2000); // 250 ms
    expect(q.silenceToFeed(), 0);
    now = now.add(const Duration(milliseconds: 90));
    expect(q.queuedSamples(), 1280);
    expect(q.silenceToFeed(), 0);
    now = now.add(const Duration(milliseconds: 20)); // 140 ms left < 150 ms low water
    expect(q.silenceToFeed(), 2000);
  });

  test('feeds append behind what is still queued', () {
    q.fed(2000);
    now = now.add(const Duration(milliseconds: 100));
    q.fed(480);
    expect(q.queuedSamples(), 1200 + 480);
  });

  test('the player report corrects drift', () {
    q.fed(8000);
    q.sync(400);
    expect(q.queuedSamples(), 400);
    expect(q.silenceToFeed(), 2000);
  });

  test('topping up keeps latency bounded', () {
    var maxQueued = 0;
    for (var i = 0; i < 600; i++) { // 60 s of 100 ms ticks
      final n = q.silenceToFeed();
      if (n > 0) q.fed(n);
      if (q.queuedSamples() > maxQueued) maxQueued = q.queuedSamples();
      expect(q.queuedSamples(), greaterThan(0));
      now = now.add(const Duration(milliseconds: 100));
    }
    expect(maxQueued, lessThan(3200)); // < 400 ms
  });
}
