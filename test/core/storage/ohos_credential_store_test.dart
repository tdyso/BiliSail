import 'package:bilisail/core/storage/credential_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.bilisail/ohos_secure_store');
  final calls = <MethodCall>[];
  final storage = <String, String>{};
  /** When set, the Nth-and-later `set` calls fail with a storage error. */
  int failSetsFrom = -1;
  int setCalls = 0;

  OhosCredentialStore storeFor() => OhosCredentialStore(
    channel: channel,
    ohosPlatform: true,
  );

  setUp(() {
    calls.clear();
    storage.clear();
    failSetsFrom = -1;
    setCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final arguments = call.arguments as Map<Object?, Object?>;
          final key = arguments['key'] as String;
          switch (call.method) {
            case 'get':
              return storage[key];
            case 'set':
              if (setCalls++ >= failSetsFrom && failSetsFrom >= 0) {
                throw PlatformException(
                  code: 'storage_error',
                  details: '24000008',
                );
              }
              storage[key] = arguments['value'] as String;
              return null;
            case 'remove':
              storage.remove(key);
              return null;
            default:
              throw MissingPluginException();
          }
        });
  });

  tearDown(() {
    failSetsFrom = -1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('round-trips a snapshot through the platform store', () async {
    final store = storeFor();
    await store.write('session-1');
    expect(calls.map((call) => call.method), containsAll(['set', 'set']));
    expect(await store.read(), 'session-1');
    await store.delete();
    expect(await store.read(), isNull);
  });

  test('keeps the last valid snapshot when an overwrite fails', () async {
    final store = storeFor();
    await store.write('session-1');
    // The inactive-slot write succeeds but the active-reference write fails.
    failSetsFrom = 1;
    await expectLater(store.write('session-2'), throwsStateError);
    expect(await store.read(), 'session-1');
  });

  test('missing slots report signed-out instead of restoring', () async {
    final store = storeFor();
    await store.writeValue('${store.keyPrefix}.a', 'stale');
    // No active reference: the orphan slot must not be restored.
    expect(await store.read(), isNull);
  });

  test('refuses to run on other platforms', () async {
    final store = OhosCredentialStore(channel: channel, ohosPlatform: false);
    await expectLater(store.read(), throwsUnsupportedError);
    expect(calls, isEmpty);
  });
}
