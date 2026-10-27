/*
 * OpenHarmony secure storage for BiliSail credentials.
 *
 * `flutter_secure_storage` has no OHOS implementation, so the Dart
 * `CredentialStore` would throw `MissingPluginException` and every login
 * failed right after the QR scan was confirmed. This plugin exposes the
 * system Asset Store Kit (encrypted, per-application storage) through a
 * method channel; values never reach ordinary files, settings or logs.
 */

import {
  Any,
  BinaryMessenger,
  FlutterPlugin,
  FlutterPluginBinding,
  Log,
  MethodCall,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

const TAG = 'OhosSecureStorePlugin';
const CHANNEL = 'dev.bilisail/ohos_secure_store';

/** Aliases become asset keys; keep them to a predictable, safe charset. */
function validKey(key: string): boolean {
  return key.length > 0 && key.length <= 128 && /^[A-Za-z0-9._-]+$/.test(key);
}

function textToBytes(text: string): Uint8Array {
  const encoder = new util.TextEncoder('utf-8');
  return encoder.encodeInto(text);
}

function bytesToText(bytes: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeWithStream(bytes);
}

function aliasOf(key: string): asset.AssetMap {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, textToBytes(key));
  return query;
}

/** The ASSET service caps one SECRET at 1024 bytes; keep chunking below it. */
const CHUNK_SIZE = 900;
const MANIFEST_SUFFIX = '.m';
const CHUNK_PREFIX = '.c';

class SecureStore {
  /** The ASSET service reports a missing item as 24000002. */
  static isNotFound(error: BusinessError): boolean {
    return error.code === 24000002;
  }

  /** Returns the stored bytes, or null when the entry does not exist. */
  private async readEntry(alias: string): Promise<Uint8Array | null> {
    const query = aliasOf(alias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let matches: Array<asset.AssetMap>;
    try {
      matches = await asset.query(query);
    } catch (error) {
      const failure = error as BusinessError;
      if (SecureStore.isNotFound(failure)) return null;
      throw new Error(`asset query failed: ${failure.code} ${failure.message}`);
    }
    for (const match of matches) {
      const secret = match.get(asset.Tag.SECRET);
      if (secret instanceof Uint8Array) {
        return secret;
      }
    }
    return null;
  }

  private async addEntry(alias: string, bytes: Uint8Array): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, textToBytes(alias));
    attributes.set(asset.Tag.SECRET, bytes);
    // Available from power-on: the app must reach saved credentials after a
    // reboot without requiring the lock screen to be unlocked first.
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_POWERED_ON);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  private async removeEntry(alias: string): Promise<void> {
    try {
      await asset.remove(aliasOf(alias));
    } catch (error) {
      const failure = error as BusinessError;
      if (!SecureStore.isNotFound(failure)) {
        throw new Error(`asset remove failed: ${failure.code} ${failure.message}`);
      }
    }
  }

  private async readChunkCount(key: string): Promise<number | null> {
    const manifest = await this.readEntry(`${key}${MANIFEST_SUFFIX}`);
    if (manifest === null) return null;
    const count = parseInt(bytesToText(manifest), 10);
    if (!Number.isFinite(count) || count < 1 || count > 512) {
      throw new Error('asset manifest is malformed');
    }
    return count;
  }

  private concat(parts: Uint8Array[]): Uint8Array {
    let total = 0;
    for (const part of parts) {
      total += part.length;
    }
    const merged = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      merged.set(part, offset);
      offset += part.length;
    }
    return merged;
  }

  /**
   * Chunked values keep each SECRET within the service limit. The manifest is
   * removed first and written last, so an interrupted write leaves no
   * readable half-updated snapshot and `get` reports signed-out instead.
   */
  async get(key: string): Promise<string | null> {
    const count = await this.readChunkCount(key);
    if (count === null) {
      // Compat: entries written before chunking lived under the bare alias.
      const plain = await this.readEntry(key);
      return plain === null ? null : bytesToText(plain);
    }
    const parts: Uint8Array[] = [];
    for (let index = 0; index < count; index++) {
      const chunk = await this.readEntry(`${key}${CHUNK_PREFIX}${index}`);
      if (chunk === null) {
        throw new Error(`asset chunk ${index} is missing`);
      }
      parts.push(chunk);
    }
    return bytesToText(this.concat(parts));
  }

  async set(key: string, value: string): Promise<void> {
    const bytes = textToBytes(value);
    const count = Math.max(1, Math.ceil(bytes.length / CHUNK_SIZE));
    await this.removeEntry(`${key}${MANIFEST_SUFFIX}`);
    for (let index = 0; index < count; index++) {
      const start = index * CHUNK_SIZE;
      await this.addEntry(`${key}${CHUNK_PREFIX}${index}`, bytes.subarray(start, start + CHUNK_SIZE));
    }
    await this.addEntry(`${key}${MANIFEST_SUFFIX}`, textToBytes(`${count}`));
  }

  async remove(key: string): Promise<void> {
    const count = await this.readChunkCount(key);
    if (count !== null) {
      for (let index = 0; index < count; index++) {
        await this.removeEntry(`${key}${CHUNK_PREFIX}${index}`);
      }
    }
    await this.removeEntry(`${key}${MANIFEST_SUFFIX}`);
    await this.removeEntry(key);
  }
}

function readKey(call: MethodCall): string | null {
  const value: Any = call.argument('key');
  if (typeof value !== 'string') return null;
  const key = value as string;
  return validKey(key) ? key : null;
}

export default class OhosSecureStorePlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;
  private readonly store = new SecureStore();

  getUniqueClassName(): string {
    return 'OhosSecureStorePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    const messenger: BinaryMessenger = binding.getBinaryMessenger();
    const channel = new MethodChannel(messenger, CHANNEL);
    this.channel = channel;
    channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.handle(call, result);
      },
    });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    const key = readKey(call);
    if (key === null) {
      result.error('invalid_key', 'The storage key is missing or malformed.', null);
      return;
    }
    try {
      switch (call.method) {
        case 'get': {
          const value = await this.store.get(key);
          result.success(value);
          return;
        }
        case 'set': {
          const raw: Any = call.argument('value');
          if (typeof raw !== 'string') {
            result.error('invalid_value', 'The storage value must be text.', null);
            return;
          }
          await this.store.set(key, raw as string);
          result.success(null);
          return;
        }
        case 'remove': {
          await this.store.remove(key);
          result.success(null);
          return;
        }
        default:
          result.notImplemented();
      }
    } catch (error) {
      const failure = error as BusinessError;
      Log.e(TAG, `method ${call.method} failed: ${failure.code} ${failure.message}`);
      result.error('storage_error', `${failure.code}`, `${failure.message ?? ''}`);
    }
  }
}
