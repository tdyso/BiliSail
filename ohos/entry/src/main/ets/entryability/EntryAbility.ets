
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import OhosAvPlayerPlugin from '../plugins/OhosAvPlayerPlugin';
import OhosSecureStorePlugin from '../plugins/OhosSecureStorePlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // BiliSail-owned plugin: the generated registrant is rewritten by
    // `flutter build`, so native playback is attached here instead.
    flutterEngine.getPlugins()?.add(new OhosAvPlayerPlugin())
    // Secure credential storage backed by the Asset Store Kit.
    flutterEngine.getPlugins()?.add(new OhosSecureStorePlugin())
  }
}
