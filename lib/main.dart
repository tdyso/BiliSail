import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/bili_app.dart';
import 'app/dependencies.dart';
import 'app/release_smoke.dart';
import 'core/presentation/bili_widgets_binding.dart';
import 'core/presentation/window_input_focus.dart';
import 'core/platform/macos_application_window.dart';
import 'core/storage/app_database.dart';
import 'core/storage/credential_store.dart';

Future<void> main(List<String> arguments) async {
  BiliWidgetsBinding.ensureInitialized();
  WindowInputFocus.instance.initialize();
  ReleaseSmokeRequest? smoke;
  var smokeHadError = false;
  try {
    if (Platform.isMacOS) smoke = ReleaseSmokeRequest.parse(arguments);
  } on FormatException {
    exit(1);
  }
  if (smoke != null) {
    // Do not log exception details, which can include plugin or network data.
    FlutterError.onError = (_) => smokeHadError = true;
    PlatformDispatcher.instance.onError = (_, _) {
      smokeHadError = true;
      return true;
    };
  } else if (Platform.isOhos) {
    // Temporary OHOS porting diagnosis: dump raw exceptions and top stack
    // frames without StackFrame parsing, which can itself overflow on the
    // OHOS engine's small UI-isolate stack.
    FlutterError.onError = (details) {
      debugPrint('BILISAIL_DIAG: ${details.exception}');
      if (details.stack != null) {
        for (final line in details.stack.toString().split('\n').take(250)) {
          debugPrint('BILISAIL_DIAG: $line');
        }
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('BILISAIL_DIAG_UNCAUGHT: $error');
      for (final line in stack.toString().split('\n').take(45)) {
        debugPrint('BILISAIL_DIAG_UNCAUGHT: $line');
      }
      return false;
    };
  }
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString(
      'assets/fonts/harmonyos_sans/LICENSE.txt',
    );
    // The supplied license has trailing NUL padding; retain the source intact.
    yield LicenseEntryWithLineBreaks([
      'HarmonyOS Sans',
    ], license.replaceAll('\u0000', ''));
  });
  MacOSApplicationWindow? applicationWindow;
  void present(Widget app) {
    final window = applicationWindow;
    if (window == null) {
      runApp(app);
    } else {
      window.present(app);
    }
  }

  try {
    applicationWindow = await MacOSApplicationWindow.create();
    await applicationWindow?.prepare();
    if (smoke != null && smoke.phase == 'cleanup') {
      await smoke.probeCredentials();
      stdout.writeln(smoke.successMarker);
      await stdout.flush();
      exit(0);
    }
    final dependencies = await AppDependencies.create(
      // Smoke launches cannot restore real accounts or modify the user's DB.
      credentials: smoke == null
          ? null
          : SystemCredentialStore(keyPrefix: '${smoke.prefix}.bootstrap'),
      databaseOverride: smoke == null
          ? null
          : AppDatabase(NativeDatabase.memory()),
      windowOverride: applicationWindow?.service,
    );
    final app = dependencies.scope(BiliApp(dependencies: dependencies));
    present(app);
    if (smoke != null) {
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      if (smoke.phase == 'startup') {
        await Future<void>.delayed(const Duration(seconds: 3));
        final mainWindow = applicationWindow;
        if (mainWindow == null) {
          throw StateError('macOS startup requires an explicit main window');
        }
        await verifyMacOSPlaybackWindows(mainWindow, app);
      }
      await smoke.probeCredentials();
      present(const SizedBox.shrink());
      await WidgetsBinding.instance.endOfFrame;
      await dependencies.close();
      if (smokeHadError) throw StateError('Release application failed');
      stdout.writeln(smoke.successMarker);
      await stdout.flush();
      exit(0);
    }
  } catch (error, stack) {
    if (Platform.isOhos) {
      debugPrint('BILISAIL_DIAG_MAIN: $error');
      for (final line in stack.toString().split('\n').take(30)) {
        debugPrint('BILISAIL_DIAG_MAIN: $line');
      }
    }
    if (smoke != null) {
      stderr.writeln('BILISAIL_RELEASE_SMOKE_FAILED:${smoke.phase}');
      exit(1);
    }
    if (Platform.isMacOS && applicationWindow == null) {
      // There is no native Flutter window to display the error in. Do not
      // attach runApp to the engine's unbacked compatibility view 0.
      stderr.writeln('BILISAIL_MAIN_WINDOW_FAILED');
      exit(1);
    }
    present(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'BiliSail 启动失败。请确认应用目录完整、本地数据目录可写，随后重新启动。',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
