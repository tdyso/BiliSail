import 'package:bili_player/bili_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The engine drives the system AVPlayer through this channel; the plugin
/// answers `create` with a native instance id and a texture id.
const _channelName = 'dev.bilisail/ohos_avplayer';

MediaTrack _track(String url, {Map<String, String> headers = const {}}) =>
    MediaTrack(
      uri: Uri.parse(url),
      requestPolicy: MediaRequestPolicy(headers: headers),
    );

void _emit(Map<String, Object?> event) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.handlePlatformMessage(
    _channelName,
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('event', <String, Object?>{'id': 7, ...event}),
    ),
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = const MethodChannel(_channelName);
  late List<MethodCall> calls;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'create') {
        return <String, Object?>{'id': 7, 'textureId': 42};
      }
      if (call.method == 'open') {
        return <String, Object?>{
          'durationMs': 125000,
          'width': 1920,
          'height': 1080,
          'positionMs': 0,
        };
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  List<String> methods() =>
      calls.map((call) => call.method).toList(growable: false);

  test('DASH pair opens one video and one audio resource', () async {
    final engine = OhosAvPlayerEngine();
    await engine.open(
      DashPairSource(
        video: _track(
          'https://cdn.example/video.m4s',
          headers: {'Referer': 'https://www.bilibili.com/'},
        ),
        audio: _track(
          'https://cdn.example/audio.m4s',
          headers: {'Referer': 'https://www.bilibili.com/'},
        ),
      ),
      const OpenOptions(volume: 60, rate: 1.25),
    );

    expect(methods(), ['create', 'open']);
    final arguments = calls[1].arguments as Map<Object?, Object?>;
    expect(arguments['id'], 7);
    expect(arguments['videoUrl'], 'https://cdn.example/video.m4s');
    expect(arguments['audioUrl'], 'https://cdn.example/audio.m4s');
    expect(arguments['videoHeaders'], {'Referer': 'https://www.bilibili.com/'});
    expect(arguments['rate'], 1.25);
    expect(arguments['volume'], 60);
    expect(arguments['startPositionMs'], 0);

    // `play` defaults to false, so the opened source waits paused.
    expect(engine.currentSnapshot.phase, PlaybackPhase.paused);
    expect(engine.currentSnapshot.duration, const Duration(milliseconds: 125000));
    expect(engine.currentSnapshot.videoDimensions, const VideoDimensions(1920, 1080));

    await engine.dispose();
  });

  test('native events update the position, buffer and video size', () async {
    final engine = OhosAvPlayerEngine();
    final snapshots = <PlaybackSnapshot>[];
    engine.snapshots.listen(snapshots.add);
    await engine.open(
      ProgressiveSource(_track('https://cdn.example/movie.mp4')),
      const OpenOptions(),
    );

    _emit({'event': 'position', 'value': 30000});
    _emit({'event': 'buffered', 'value': 60000});
    _emit({'event': 'videoSize', 'width': 1280, 'height': 720});
    _emit({'event': 'buffering', 'value': true});
    _emit({'event': 'seekDone'});
    _emit({'event': 'completed'});

    expect(engine.currentSnapshot.position, const Duration(seconds: 30));
    expect(engine.currentSnapshot.buffered, const Duration(seconds: 60));
    expect(engine.currentSnapshot.videoDimensions, const VideoDimensions(1280, 720));
    expect(engine.currentSnapshot.isBuffering, isFalse);
    expect(engine.currentSnapshot.phase, PlaybackPhase.ended);
    expect(snapshots, isNotEmpty);

    await engine.dispose();
  });

  test('play, pause and seek are forwarded to the native instance', () async {
    final engine = OhosAvPlayerEngine();
    await engine.open(
      ProgressiveSource(_track('https://cdn.example/movie.mp4')),
      const OpenOptions(play: true),
    );
    expect(engine.currentSnapshot.phase, PlaybackPhase.playing);

    await engine.pause();
    expect(engine.currentSnapshot.phase, PlaybackPhase.paused);

    await engine.seek(const Duration(seconds: 42));
    expect(engine.currentSnapshot.position, const Duration(seconds: 42));

    await engine.play();
    expect(engine.currentSnapshot.phase, PlaybackPhase.playing);

    await engine.setRate(1.5);
    await engine.setVolume(30);

    expect(methods(), [
      'create',
      'open',
      'play',
      'pause',
      'seek',
      'play',
      'setRate',
      'setVolume',
    ]);
    final seek = calls[4].arguments as Map<Object?, Object?>;
    expect(seek['positionMs'], 42000);
    final rate = calls[6].arguments as Map<Object?, Object?>;
    expect(rate['rate'], 1.5);

    await engine.dispose();
    expect(methods().last, 'dispose');
  });

  test('a discarded native open is reported as a native failure', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'create') return null;
      return null;
    });
    final engine = OhosAvPlayerEngine();
    final failures = <PlayerFailure>[];
    engine.failures.listen(failures.add);

    await expectLater(
      engine.open(
        ProgressiveSource(_track('https://cdn.example/movie.mp4')),
        const OpenOptions(),
      ),
      throwsA(
        isA<PlayerFailure>().having(
          (failure) => failure.kind,
          'kind',
          PlayerFailureKind.nativePlayback,
        ),
      ),
    );
    expect(engine.currentSnapshot.phase, PlaybackPhase.failed);
    expect(failures, hasLength(1));

    await engine.dispose();
  });

  test('a native command error fails the active generation', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'create') {
        return <String, Object?>{'id': 7, 'textureId': 42};
      }
      if (call.method == 'open') return <String, Object?>{'durationMs': 1000};
      if (call.method == 'play') {
        throw PlatformException(code: '5400102', message: 'not playing');
      }
      return null;
    });
    final engine = OhosAvPlayerEngine();
    await engine.open(
      ProgressiveSource(_track('https://cdn.example/movie.mp4')),
      const OpenOptions(),
    );

    await expectLater(
      engine.play(),
      throwsA(
        isA<PlayerFailure>().having(
          (failure) => failure.kind,
          'kind',
          PlayerFailureKind.nativePlayback,
        ),
      ),
    );
    expect(engine.currentSnapshot.phase, PlaybackPhase.failed);

    await engine.dispose();
  });

  test('unsupported headers never reach the native player', () async {
    final engine = OhosAvPlayerEngine();
    await expectLater(
      engine.open(
        ProgressiveSource(
          _track(
            'https://cdn.example/movie.mp4',
            headers: {'Cookie': 'SESSDATA=secret'},
          ),
        ),
        const OpenOptions(),
      ),
      throwsA(
        isA<PlayerFailure>().having(
          (failure) => failure.kind,
          'kind',
          PlayerFailureKind.unsupportedHeaders,
        ),
      ),
    );
    expect(calls, isEmpty);

    await engine.dispose();
  });
}
