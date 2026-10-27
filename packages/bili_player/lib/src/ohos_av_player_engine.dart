import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'media_source_validation.dart';
import 'player_contract.dart';
import 'player_diagnostics.dart';
import 'video_composition.dart';
import 'video_output.dart';

/// OpenHarmony backend built on the system `AVPlayer`.
///
/// The platform ships no libmpv asset, so media-kit cannot demux a DASH pair.
/// A DASH pair therefore uses one muted video player plus one audio-only
/// player; the audio player is the clock and the video player is corrected by
/// seeking when it drifts. Progressive, HLS and local files use one player.
///
/// Video pixels reach Flutter through a `Texture` whose surface is owned here,
/// so the widget tree composes video with danmaku and controls like any layer.
final class OhosAvPlayerEngine implements PlayerEngine, VideoOutputSource {
  OhosAvPlayerEngine({this.onDiagnostic});

  final void Function(PlayerDiagnosticEvent)? onDiagnostic;

  final _OhosAvVideoOutput _videoOutput = _OhosAvVideoOutput();
  final _snapshots = StreamController<PlaybackSnapshot>.broadcast(sync: true);
  final _failures = StreamController<PlayerFailure>.broadcast(sync: true);

  Future<void> _commands = Future.value();
  PlaybackSnapshot _snapshot = const PlaybackSnapshot(
    phase: PlaybackPhase.idle,
    generation: 0,
  );
  int _generation = 0;
  int? _nativeId;
  bool _disposed = false;

  @override
  VideoOutput get videoOutput => _videoOutput;

  @override
  Stream<PlaybackSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<PlayerFailure> get failures => _failures.stream;
  @override
  PlaybackSnapshot get currentSnapshot => _snapshot;
  @override
  PlayerCapabilities get capabilities =>
      const PlayerCapabilities(externalAudio: true, externalAudioHeaders: true);

  void _diagnose(PlayerDiagnosticKind kind, {PlayerFailureKind? failureKind}) =>
      onDiagnostic?.call(
        PlayerDiagnosticEvent(
          kind: kind,
          snapshot: _snapshot,
          failureKind: failureKind,
        ),
      );

  void _publish(PlaybackSnapshot value) {
    if (_disposed || _snapshots.isClosed) return;
    _snapshot = value;
    _videoOutput.updateVideoDimensions(value.videoDimensions);
    _snapshots.add(value);
  }

  void _fail(PlayerFailure failure) {
    if (_disposed || _failures.isClosed || failure.generation != _generation) {
      return;
    }
    _diagnose(PlayerDiagnosticKind.failed, failureKind: failure.kind);
    _publish(
      _snapshot.copyWith(
        phase: PlaybackPhase.failed,
        isBuffering: false,
        isSeeking: false,
      ),
    );
    _failures.add(failure);
  }

  Future<void> _serial(Future<void> Function() operation) {
    final result = _commands.then((_) => operation());
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _requireActive() {
    if (_disposed) {
      throw PlayerFailure(
        PlayerFailureKind.disposed,
        'Player is disposed.',
        _generation,
      );
    }
  }

  int _advanceGeneration() {
    final value = ++_generation;
    _videoOutput.advanceGeneration();
    return value;
  }

  static Future<Map<Object?, Object?>> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final result = await _OhosAvChannel.instance.invoke(method, arguments);
    if (result is Map) return result;
    return const <Object?, Object?>{};
  }

  int? _nativeIdOf(Map<Object?, Object?> result) {
    final value = result['id'];
    return value is int ? value : null;
  }

  Future<void> _releaseNative() async {
    final id = _nativeId;
    _nativeId = null;
    _videoOutput.clear();
    if (id == null) return;
    _OhosAvChannel.instance.detach(id);
    try {
      await _invoke('dispose', {'id': id}).timeout(
        const Duration(seconds: 5),
      );
    } on Object {
      // The native side releases the player and texture even when the reply is
      // lost; the engine must not keep the retired instance reachable.
    }
  }

  @override
  Future<void> open(ResolvedMediaSource source, OpenOptions options) {
    _requireActive();
    final generation = _advanceGeneration();
    _publish(
      PlaybackSnapshot(
        phase: PlaybackPhase.opening,
        generation: generation,
        desiredPlaying: options.play,
        rate: options.rate,
        volume: options.volume,
        isSeeking: options.startPosition > Duration.zero,
      ),
    );
    _diagnose(PlayerDiagnosticKind.openStarted);
    return _serial(() async {
      if (generation != _generation || _disposed) return;
      await _releaseNative();
      if (generation != _generation || _disposed) return;
      try {
        final validated = validateMediaSource(source, options, generation);
        final video = validated.video;
        final audio = validated.audio;
        final deadline = Duration(
          milliseconds: options.openTimeout.inMilliseconds,
        );
        final created = await _invoke('create', const {}).timeout(deadline);
        final id = _nativeIdOf(created);
        final textureId = created['textureId'];
        if (id == null || textureId is! int) {
          throw StateError('Native player did not expose a texture.');
        }
        _nativeId = id;
        _OhosAvChannel.instance.attach(id, this);
        _videoOutput.bind(textureId);
        if (generation != _generation || _disposed) {
          await _releaseNative();
          return;
        }
        final opened = await _invoke('open', {
          'id': id,
          'videoUrl': video.uri.toString(),
          'videoHeaders': video.requestPolicy.headers,
          if (audio != null) ...{
            'audioUrl': audio.uri.toString(),
            'audioHeaders': audio.requestPolicy.headers,
          },
          'startPositionMs': options.startPosition.inMilliseconds,
          'rate': options.rate,
          'volume': options.volume,
        }).timeout(deadline);
        if (generation != _generation || _disposed) {
          await _releaseNative();
          return;
        }
        final duration = _duration(opened['durationMs']);
        final width = opened['width'];
        final height = opened['height'];
        final dimensions = width is int && height is int && width > 0 && height > 0
            ? VideoDimensions(width, height)
            : null;
        final position = _duration(opened['positionMs']);
        _publish(
          _snapshot.copyWith(
            phase: PlaybackPhase.ready,
            duration: duration,
            position: position,
            videoDimensions: dimensions,
            isSeeking: false,
          ),
        );
        _diagnose(PlayerDiagnosticKind.openReady);
        if (options.play) {
          await _invoke('play', {'id': id}).timeout(deadline);
          if (generation == _generation && !_disposed) {
            _publish(_snapshot.copyWith(phase: PlaybackPhase.playing));
          }
        } else if (generation == _generation && !_disposed) {
          _publish(_snapshot.copyWith(phase: PlaybackPhase.paused));
        }
      } on PlayerFailure catch (error) {
        _fail(error);
        await _releaseNative();
        rethrow;
      } on Object {
        final failure = PlayerFailure(
          PlayerFailureKind.nativePlayback,
          'Native player could not open this source.',
          generation,
        );
        _fail(failure);
        await _releaseNative();
        throw failure;
      }
    });
  }

  static Duration _duration(Object? milliseconds) {
    if (milliseconds is! num) return Duration.zero;
    final value = milliseconds.round();
    return value <= 0 ? Duration.zero : Duration(milliseconds: value);
  }

  /// Native events are routed by instance id, so a retired player cannot
  /// change the current snapshot.
  void _handleNativeEvent(Map<Object?, Object?> event) {
    if (_disposed) return;
    final value = event['value'];
    switch (event['event']) {
      case 'position':
        if (value is num) {
          _publish(_snapshot.copyWith(position: _duration(value)));
        }
      case 'duration':
        if (value is num) {
          _publish(_snapshot.copyWith(duration: _duration(value)));
        }
      case 'buffered':
        if (value is num) {
          _publish(_snapshot.copyWith(buffered: _duration(value)));
        }
      case 'videoSize':
        final width = event['width'];
        final height = event['height'];
        if (width is int && height is int && width > 0 && height > 0) {
          _publish(_snapshot.copyWith(videoDimensions: VideoDimensions(width, height)));
        }
      case 'buffering':
        final buffering = value == true;
        if (_snapshot.phase == PlaybackPhase.failed ||
            _snapshot.phase == PlaybackPhase.ended) {
          return;
        }
        if (_snapshot.phase == PlaybackPhase.opening) return;
        _publish(
          _snapshot.copyWith(
            isBuffering: buffering,
            phase: buffering
                ? PlaybackPhase.buffering
                : (_snapshot.desiredPlaying
                      ? PlaybackPhase.playing
                      : PlaybackPhase.paused),
          ),
        );
      case 'seekDone':
        if (_snapshot.isSeeking) {
          _publish(_snapshot.copyWith(isSeeking: false));
        }
      case 'completed':
        if (_snapshot.phase != PlaybackPhase.failed &&
            _snapshot.phase != PlaybackPhase.ended &&
            _snapshot.phase != PlaybackPhase.opening) {
          _publish(
            _snapshot.copyWith(
              phase: PlaybackPhase.ended,
              desiredPlaying: false,
              isBuffering: false,
              isSeeking: false,
            ),
          );
        }
      case 'error':
        _fail(
          PlayerFailure(
            PlayerFailureKind.nativePlayback,
            '系统播放器报告播放错误，请重新加载或切换清晰度。',
            _generation,
          ),
        );
    }
  }

  Future<void> _command(
    Future<void> Function(int id) operation, {
    PlaybackSnapshot Function(PlaybackSnapshot)? optimistic,
  }) {
    _requireActive();
    final generation = _generation;
    return _serial(() async {
      if (generation != _generation || _disposed) return;
      final id = _nativeId;
      if (id == null) return;
      if (optimistic != null) _publish(optimistic(_snapshot));
      try {
        await operation(id).timeout(const Duration(seconds: 15));
      } on PlayerFailure {
        rethrow;
      } on Object {
        if (generation != _generation || _disposed) return;
        final failure = PlayerFailure(
          PlayerFailureKind.nativePlayback,
          'Native playback command failed.',
          generation,
        );
        _fail(failure);
        throw failure;
      }
    });
  }

  @override
  Future<void> play() {
    final generation = _generation;
    return _command(
      (id) async {
        await _invoke('play', {'id': id});
        if (_disposed || generation != _generation || _nativeId != id) return;
        _publish(
          _snapshot.copyWith(
            phase: PlaybackPhase.playing,
            desiredPlaying: true,
            isBuffering: false,
          ),
        );
      },
      optimistic: (s) => s.copyWith(
        desiredPlaying: true,
        phase: s.phase == PlaybackPhase.ended ? PlaybackPhase.paused : s.phase,
      ),
    );
  }

  @override
  Future<void> pause() {
    final generation = _generation;
    return _command(
      (id) async {
        await _invoke('pause', {'id': id});
        if (_disposed || generation != _generation || _nativeId != id) return;
        _publish(
          _snapshot.copyWith(
            phase: PlaybackPhase.paused,
            desiredPlaying: false,
            isBuffering: false,
          ),
        );
      },
      optimistic: (s) => s.copyWith(desiredPlaying: false),
    );
  }

  @override
  Future<void> seek(Duration target) {
    if (target < Duration.zero) throw ArgumentError.value(target, 'target');
    final generation = _generation;
    return _command(
      (id) async {
        await _invoke('seek', {
          'id': id,
          'positionMs': target.inMilliseconds,
        });
        if (_disposed || generation != _generation || _nativeId != id) return;
        _publish(_snapshot.copyWith(position: target, isSeeking: false));
      },
      optimistic: (s) => s.copyWith(
        isSeeking: true,
        phase: s.phase == PlaybackPhase.ended ? PlaybackPhase.paused : s.phase,
      ),
    );
  }

  @override
  Future<void> setRate(double rate) {
    if (!rate.isFinite || rate <= 0) throw ArgumentError.value(rate, 'rate');
    return _command(
      (id) => _invoke('setRate', {'id': id, 'rate': rate}),
      optimistic: (s) => s.copyWith(rate: rate),
    );
  }

  @override
  Future<void> setVolume(double volume) {
    if (!volume.isFinite || volume < 0 || volume > 100) {
      throw ArgumentError.value(volume, 'volume');
    }
    return _command(
      (id) => _invoke('setVolume', {'id': id, 'volume': volume}),
      optimistic: (s) => s.copyWith(volume: volume),
    );
  }

  @override
  Future<void> stop() {
    _requireActive();
    final generation = _advanceGeneration();
    _publish(
      PlaybackSnapshot(phase: PlaybackPhase.idle, generation: generation),
    );
    return _serial(_releaseNative);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _advanceGeneration();
    await _serial(_releaseNative);
    _disposed = true;
    _videoOutput.dispose();
    await _snapshots.close();
    await _failures.close();
  }
}

/// Routes native instance events to the owning engine.
///
/// One method channel serves every playback tab, so events carry the instance
/// id that created them.
final class _OhosAvChannel {
  _OhosAvChannel() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const MethodChannel _channel = MethodChannel(
    'dev.bilisail/ohos_avplayer',
  );
  static final _OhosAvChannel instance = _OhosAvChannel();

  final Map<int, OhosAvPlayerEngine> _engines = <int, OhosAvPlayerEngine>{};

  void attach(int id, OhosAvPlayerEngine engine) => _engines[id] = engine;

  void detach(int id) => _engines.remove(id);

  Future<Object?> invoke(String method, Map<String, Object?> arguments) =>
      _channel.invokeMethod<Object?>(method, arguments);

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'event') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final id = arguments['id'];
    final engine = id is int ? _engines[id] : null;
    engine?._handleNativeEvent(arguments.cast<Object?, Object?>());
  }
}

/// A surface texture owned by the native AVPlayer.
final class _OhosAvVideoOutput implements FlutterVideoOutput {
  final ValueNotifier<_OhosVideoSurfaceModel> _model =
      ValueNotifier(const _OhosVideoSurfaceModel(null, null));
  VideoDimensions? _dimensions;
  bool _disposed = false;

  void bind(int textureId) {
    if (_disposed) return;
    _model.value = _OhosVideoSurfaceModel(textureId, _dimensions);
  }

  void clear() {
    if (_disposed) return;
    _dimensions = null;
    _model.value = const _OhosVideoSurfaceModel(null, null);
  }

  void advanceGeneration() => clear();

  void updateVideoDimensions(VideoDimensions? dimensions) {
    if (_disposed || dimensions == _dimensions) return;
    _dimensions = dimensions;
    final textureId = _model.value.textureId;
    if (textureId == null) return;
    _model.value = _OhosVideoSurfaceModel(textureId, dimensions);
  }

  @override
  void attach(Object owner) {}

  @override
  void updateViewport(
    Object owner, {
    required double logicalWidth,
    required double logicalHeight,
    required double devicePixelRatio,
  }) {}

  @override
  void detach(Object owner) {}

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _model.dispose();
  }

  @override
  Widget buildVideoSurface() => ValueListenableBuilder<_OhosVideoSurfaceModel>(
    valueListenable: _model,
    builder: (context, model, _) {
      final textureId = model.textureId;
      if (textureId == null) return const ColoredBox(color: Color(0xFF000000));
      final dimensions = model.dimensions;
      // FittedBox keeps the decoded aspect ratio inside the panel's viewport.
      return ColoredBox(
        color: const Color(0xFF000000),
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: (dimensions?.width ?? 16).toDouble(),
            height: (dimensions?.height ?? 9).toDouble(),
            child: Texture(
              textureId: textureId,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      );
    },
  );
}

final class _OhosVideoSurfaceModel {
  const _OhosVideoSurfaceModel(this.textureId, this.dimensions);

  final int? textureId;
  final VideoDimensions? dimensions;
}

/// True when the platform provides the OpenHarmony AVPlayer backend.
bool get hasOhosAvPlayerBackend => Platform.isOhos;
