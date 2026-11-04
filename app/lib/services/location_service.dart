import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../src/rust/api.dart';

/// LIP reasons for sending (ETSI TS 100 392-18-1), as accepted by
/// `TetraClient.sendLocation`.
class LipReason {
  static const powerOn = 0;
  static const emergency = 2;
  static const ptt = 3;
  static const user = 20;
  static const periodic = 129;
}

/// Tracks the GPS fix and hands LIP reports to [send] on a timer and on
/// demand (PTT, emergency).
class LocationService {
  LocationService(this.send);

  final void Function(LocationInfo loc, int reason) send;
  StreamSubscription<Position>? _sub;
  Timer? _timer;
  Position? last;

  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }

  Future<void> start(Duration interval) async {
    await stop();
    if (!await ensurePermission()) return;
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
    ).listen((p) {
      final first = last == null;
      last = p;
      if (first) sendNow(LipReason.powerOn);
    });
    _timer = Timer.periodic(interval, (_) => sendNow(LipReason.periodic));
  }

  void sendNow(int reason) {
    final p = last;
    if (p == null) return;
    send(
      LocationInfo(
        latitude: p.latitude,
        longitude: p.longitude,
        accuracyM: p.accuracy > 0 ? p.accuracy : null,
        speedKmh: p.speed >= 0 ? p.speed * 3.6 : null,
        headingDeg: p.heading >= 0 ? p.heading : null,
      ),
      reason,
    );
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
  }
}
