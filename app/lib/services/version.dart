/// App version, equal to `version` in pubspec.yaml and to tetra_core's
/// Cargo.toml (test/version_test.dart checks all three).
const appVersion = '1.4.0';

/// The one User-Agent for every request the app makes (Brew login and
/// downloads), so servers always see the same name and version.
const userAgent = 'TetraBrewTerminal/$appVersion';
