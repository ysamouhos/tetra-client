import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/services/version.dart';

void main() {
  test('User-Agent version matches pubspec and tetra_core', () {
    final pub = RegExp(r'^version:\s*([0-9.]+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    final cargo = RegExp(r'^version\s*=\s*"([0-9.]+)"', multiLine: true).firstMatch(File('../tetra_core/Cargo.toml').readAsStringSync())!.group(1);
    expect(appVersion, pub);
    expect(cargo, pub);
    expect(userAgent, 'TetraBrewTerminal/$pub');
  });
}
