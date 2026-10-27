import 'dart:io';

import 'media_kit_engine.dart';
import 'ohos_av_player_engine.dart';
import 'player_contract.dart';
import 'player_diagnostics.dart';

/// Creates the engine that matches the host platform.
///
/// Every other platform keeps the audited media-kit backend. OpenHarmony ships
/// no libmpv asset, so it uses the system AVPlayer adapter instead.
PlayerEngine createPlatformPlayerEngine({
  void Function(PlayerDiagnosticEvent)? onDiagnostic,
}) => Platform.isOhos
    ? OhosAvPlayerEngine(onDiagnostic: onDiagnostic)
    : MediaKitEngine(onDiagnostic: onDiagnostic);
