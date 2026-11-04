import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'model/settings.dart';
import 'model/terminal_model.dart';
import 'screens/home_screen.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await RustLib.init(externalLibrary: _nativeCore());
  } catch (e, st) {
    // Without the native core nothing works; show why instead of hanging on the splash.
    runApp(_StartupError('$e\n\n$st'));
    return;
  }
  final settings = await Settings.load();
  final model = TerminalModel(settings);
  runApp(ChangeNotifierProvider.value(value: model, child: const TetraApp()));
  // Ask for permissions once the UI is up (asking before runApp can leave a black screen).
  await [Permission.microphone, Permission.notification, Permission.locationWhenInUse].request();
  try {
    await model.start();
  } catch (e) {
    model.toast = 'Startup: $e';
  }
}

/// iOS: cargokit links the Rust core into the plugin's framework, which is named
/// after the pod (rust_lib_tetra_terminal), not the crate (tetra_core). If that
/// lookup fails the symbols are already in the process (static -force_load).
/// Android/desktop: null = flutter_rust_bridge's default lookup (libtetra_core.so).
ExternalLibrary? _nativeCore() {
  if (!Platform.isIOS && !Platform.isMacOS) return null;
  try {
    return ExternalLibrary.open('rust_lib_tetra_terminal.framework/rust_lib_tetra_terminal');
  } catch (_) {
    return ExternalLibrary.process(iKnowHowToUseIt: true);
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('TETRA Terminal failed to start')),
          body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: SelectableText(message)),
        ),
      );
}

class TetraApp extends StatelessWidget {
  const TetraApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1F6F5C);
    return MaterialApp(
      title: 'TETRA Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed), useMaterial3: true),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark), useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
