import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class CredentialStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// Double-slot reference semantics shared by every secure backend.
///
/// A complete encrypted snapshot is written into the inactive slot before the
/// active reference switches, so an interrupted write can never destroy the
/// last valid session. An explicit signed-out marker prevents orphan slots
/// from restoring a login.
abstract base class SlotCredentialStore implements CredentialStore {
  SlotCredentialStore({this.keyPrefix = 'bilisail.web_session.v1'});

  final String keyPrefix;

  Future<String?> readValue(String key);
  Future<void> writeValue(String key, String value);
  Future<void> deleteValue(String key);

  @override
  Future<String?> read() async {
    final reference = await readValue('$keyPrefix.active');
    if (reference != 'a' && reference != 'b') return null;
    final current = await readValue('$keyPrefix.$reference');
    if (current != null) return current;
    return readValue('$keyPrefix.${reference == 'a' ? 'b' : 'a'}');
  }

  @override
  Future<void> write(String value) async {
    final reference = await readValue('$keyPrefix.active');
    final slot = reference == 'a' ? 'b' : 'a';
    await writeValue('$keyPrefix.$slot', value);
    await writeValue('$keyPrefix.active', slot);
  }

  @override
  Future<void> delete() async {
    await writeValue('$keyPrefix.active', 'signed_out');
    await deleteValue('$keyPrefix.a');
    await deleteValue('$keyPrefix.b');
    await deleteValue('$keyPrefix.active');
  }
}

/// Writes a complete encrypted slot before switching the active reference.
/// An explicit signed-out marker prevents orphan slots from restoring a login.
final class SystemCredentialStore extends SlotCredentialStore {
  SystemCredentialStore({
    FlutterSecureStorage? storage,
    super.keyPrefix,
  }) : _storage = storage ?? defaultStorage;

  // Ad-hoc macOS distribution cannot authorize Keychain Sharing. Keep secrets
  // in the system Keychain without requiring a provisioning profile.
  static const defaultStorage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readValue(String key) => _storage.read(key: key);

  @override
  Future<void> writeValue(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> deleteValue(String key) => _storage.delete(key: key);
}

/// OHOS credentials live in the system Asset Store Kit, which encrypts entries
/// per application. `flutter_secure_storage` ships no OHOS implementation, so
/// a missing plugin must surface instead of silently dropping the session.
final class OhosCredentialStore extends SlotCredentialStore {
  OhosCredentialStore({
    MethodChannel? channel,
    bool? ohosPlatform,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _ohosPlatform = ohosPlatform ?? Platform.isOhos;

  static const _channelName = 'dev.bilisail/ohos_secure_store';

  final MethodChannel _channel;
  final bool _ohosPlatform;

  Future<T?> _invoke<T>(
    String method,
    Map<String, Object?> arguments,
  ) async {
    if (!_ohosPlatform) {
      throw UnsupportedError('The OHOS secure store requires OpenHarmony.');
    }
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      final details = error.details is String ? error.details as String : '';
      throw StateError(
        'OHOS secure store $method failed: ${error.code} $details',
      );
    }
  }

  @override
  Future<String?> readValue(String key) => _invoke<String>('get', {'key': key});

  @override
  Future<void> writeValue(String key, String value) async {
    await _invoke<void>('set', {'key': key, 'value': value});
  }

  @override
  Future<void> deleteValue(String key) async {
    await _invoke<void>('remove', {'key': key});
  }
}

/// Picks the platform credential backend; every backend keeps the same
/// double-slot reference protocol.
CredentialStore defaultCredentialStore() {
  if (Platform.isOhos) return OhosCredentialStore();
  return SystemCredentialStore();
}
