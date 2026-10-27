/*
 * OpenHarmony AVPlayer backend for BiliSail.
 *
 * media-kit has no OpenHarmony video output, so this plugin exposes the system
 * AVPlayer through a method channel. Video is rendered into a Flutter texture
 * surface, which the Dart `OhosAvPlayerEngine` presents as a normal widget.
 *
 * A DASH pair arrives as two URLs. The system player cannot demux separate
 * audio and video resources, so the plugin owns two players: a muted video
 * player and an audio-only player. The audio player is the clock; the video
 * player is corrected by seeking when it drifts past the tolerance.
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
  SurfaceTextureEntry,
  TextureRegistry,
} from '@ohos/flutter_ohos';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'OhosAvPlayerPlugin';
const CHANNEL = 'dev.bilisail/ohos_avplayer';

/** Audio and video drift tolerated before the video player is re-seeked. */
const DRIFT_TOLERANCE_MS = 500;
/** Bound for a single seek, including a stalled network seek. */
const SEEK_TIMEOUT_MS = 4000;

class OpenRequest {
  videoUrl: string = '';
  videoHeaders: Record<string, string> | null = null;
  audioUrl: string | null = null;
  audioHeaders: Record<string, string> | null = null;
  startPositionMs: number = 0;
  rate: number = 1;
  volume: number = 100;
}

/** One playback instance, owning at most one video and one audio player. */
class AvSession {
  private readonly id: number;
  private readonly textureEntry: SurfaceTextureEntry;
  private readonly channel: MethodChannel;
  private videoPlayer: media.AVPlayer | null = null;
  private audioPlayer: media.AVPlayer | null = null;
  /** Live state of each player; AVPlayer rejects calls made in the wrong one. */
  private readonly states = new Map<media.AVPlayer, media.AVPlayerState>();
  /**
   * AVPlayer keeps a single callback per event type, so preparation waits are
   * dispatched from the listeners bound in `bindEvents`; registering another
   * `stateChange`/`error` callback there would silently replace state tracking
   * and error reporting.
   */
  private readonly stateHandlers =
    new Map<media.AVPlayer, (state: media.AVPlayerState) => void>();
  private readonly errorHandlers =
    new Map<media.AVPlayer, (error: BusinessError) => void>();
  private volume: number = 100;
  private rate: number = 1;
  private playing: boolean = false;
  private correcting: boolean = false;
  private disposed: boolean = false;
  private duration: number = 0;
  /** Last rejected command, surfaced when every player refuses to start. */
  private lastFailure: string = '';

  constructor(id: number, textureEntry: SurfaceTextureEntry, channel: MethodChannel) {
    this.id = id;
    this.textureEntry = textureEntry;
    this.channel = channel;
  }

  getTextureId(): number {
    return this.textureEntry.getTextureId();
  }

  private emit(event: string, value: number = 0): void {
    const message = new Map<string, Object>();
    message.set('id', this.id);
    message.set('event', event);
    message.set('value', value);
    this.channel.invokeMethod('event', message);
  }

  private emitSize(width: number, height: number): void {
    const message = new Map<string, Object>();
    message.set('id', this.id);
    message.set('event', 'videoSize');
    message.set('width', width);
    message.set('height', height);
    this.channel.invokeMethod('event', message);
  }

  private emitBuffering(buffering: boolean): void {
    const message = new Map<string, Object>();
    message.set('id', this.id);
    message.set('event', 'buffering');
    message.set('value', buffering);
    this.channel.invokeMethod('event', message);
  }

  private onPlayerError(error: BusinessError): void {
    if (this.disposed) return;
    Log.e(TAG, `player error ${error.code}`);
    this.emit('error', error.code);
  }

  /** Binds events shared by the video and audio players. */
  private bindEvents(player: media.AVPlayer, isVideo: boolean): void {
    player.on('stateChange', (state: media.AVPlayerState) => {
      this.states.set(player, state);
      const handler = this.stateHandlers.get(player);
      if (handler !== undefined) handler(state);
      if (this.disposed) return;
      if (state === 'completed') {
        this.playing = false;
        this.emit('completed');
      } else if (state === 'playing') {
        this.playing = true;
      } else if (state === 'paused') {
        this.playing = false;
      } else if (state === 'released') {
        this.playing = false;
      }
    });
    player.on('error', (error: BusinessError) => {
      const handler = this.errorHandlers.get(player);
      if (handler !== undefined) handler(error);
      this.onPlayerError(error);
    });
    if (!isVideo) {
      // The audio player is the clock for a DASH pair.
      player.on('timeUpdate', (time: number) => {
        if (this.disposed) return;
        this.correctVideoDrift(time);
        this.emit('position', time);
      });
      return;
    }
    player.on('timeUpdate', (time: number) => {
      if (this.disposed || this.audioPlayer !== null) return;
      this.emit('position', time);
    });
    player.on('durationUpdate', (duration: number) => {
      if (this.disposed) return;
      this.duration = duration;
      this.emit('duration', duration);
    });
    player.on('videoSizeChange', (width: number, height: number) => {
      if (this.disposed) return;
      this.emitSize(width, height);
    });
    player.on('startRenderFrame', () => {
      if (this.disposed) return;
      this.emit('firstFrame');
    });
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (this.disposed) return;
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        this.emitBuffering(true);
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.emitBuffering(false);
      } else if (infoType === media.BufferingInfoType.CACHED_DURATION) {
        // `value` is the cached span ahead of the current position.
        const position = this.videoPlayer?.currentTime ?? 0;
        const cached = position + value;
        this.emit('buffered', this.duration > 0 ? Math.min(cached, this.duration) : cached);
      }
    });
  }

  /**
   * Keeps the video player within DRIFT_TOLERANCE_MS of the audio clock.
   * Re-seeking is throttled so a slow seek cannot queue another one.
   */
  private correctVideoDrift(audioTime: number): void {
    const video = this.videoPlayer;
    if (!this.playing || video === null || this.correcting) return;
    const drift = video.currentTime - audioTime;
    if (Math.abs(drift) <= DRIFT_TOLERANCE_MS) return;
    this.correcting = true;
    try {
      video.seek(audioTime, media.SeekMode.SEEK_CLOSEST);
    } catch (error) {
      Log.w(TAG, `drift seek failed ${(error as BusinessError).code}`);
    }
    setTimeout(() => {
      this.correcting = false;
    }, 1000);
  }

  private players(): media.AVPlayer[] {
    const list: media.AVPlayer[] = [];
    if (this.audioPlayer !== null) list.push(this.audioPlayer);
    if (this.videoPlayer !== null) list.push(this.videoPlayer);
    return list;
  }

  private stateOf(player: media.AVPlayer): media.AVPlayerState {
    return this.states.get(player) ?? 'idle';
  }

  /** Reports whether a command ran; AVPlayer rejects calls in the wrong state. */
  private async attempt(action: string, run: () => Promise<void>): Promise<boolean> {
    try {
      await run();
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      this.lastFailure = `${action} ${failure.code} ${failure.message}`;
      Log.w(TAG, `${action} skipped: ${failure.code} ${failure.message}`);
      return false;
    }
  }

  /**
   * Creates the player in the idle state, assigns the source and resolves once
   * `prepared`. `surfaceId` must be assigned in the `initialized` state.
   */
  private preparePlayer(
    player: media.AVPlayer,
    url: string,
    headers: Record<string, string> | null,
    surfaceId: string | null,
  ): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled = false;
      const release = (): void => {
        this.stateHandlers.delete(player);
        this.errorHandlers.delete(player);
      };
      const fail = (error: BusinessError): void => {
        if (settled) return;
        settled = true;
        release();
        Log.e(TAG, `prepare failed ${error.code}: ${error.message}`);
        reject(new Error(error.message === undefined ? 'prepare failed' : error.message));
      };
      /** Some SDK builds return a bare promise chain that may be absent. */
      const watch = (pending: Promise<void> | undefined): void => {
        if (pending === undefined) return;
        pending.then(() => {}, (error: BusinessError) => fail(error));
      };
      // Wait through the listeners bound in `bindEvents`; an extra
      // `player.on('stateChange')` here would replace the session's own
      // listener and leave the tracked state stuck at `idle`.
      this.errorHandlers.set(player, fail);
      this.stateHandlers.set(player, (state: media.AVPlayerState) => {
        Log.i(TAG, `state ${state} surface=${surfaceId !== null}`);
        if (settled) return;
        if (state === 'initialized') {
          if (surfaceId !== null) player.surfaceId = surfaceId;
          watch(player.prepare());
        } else if (state === 'prepared') {
          settled = true;
          release();
          resolve();
        }
      });
      try {
        if (headers === null) {
          player.url = url;
        } else {
          Log.i(TAG, `setting media source with ${Object.keys(headers).length} headers`);
          watch(player.setMediaSource(media.createMediaSourceWithUrl(url, headers)));
        }
      } catch (error) {
        fail(error as BusinessError);
      }
    });
  }

  private seekPlayer(player: media.AVPlayer, positionMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      let settled = false;
      const done = (): void => {
        if (settled) return;
        settled = true;
        try {
          player.off('seekDone');
        } catch (error) {
          Log.w(TAG, 'seekDone cleanup failed');
        }
        resolve();
      };
      player.on('seekDone', (time: number) => done());
      try {
        player.seek(positionMs, media.SeekMode.SEEK_CLOSEST);
      } catch (error) {
        Log.w(TAG, `seek failed ${(error as BusinessError).code}`);
        done();
      }
      setTimeout(done, SEEK_TIMEOUT_MS);
    });
  }

  private applyVolume(): void {
    const level = Math.max(0, Math.min(1, this.volume / 100));
    // A paired audio player carries the sound; the video resource is muted.
    this.setVolumeSafely(this.videoPlayer, this.audioPlayer === null ? level : 0);
    this.setVolumeSafely(this.audioPlayer, level);
  }

  private setVolumeSafely(player: media.AVPlayer | null, level: number): void {
    if (player === null) return;
    try {
      player.setVolume(level);
    } catch (error) {
      Log.w(TAG, `setVolume skipped: ${(error as BusinessError).code}`);
    }
  }

  private applyRate(): void {
    for (const player of this.players()) {
      try {
        player.setSpeed(this.rate);
      } catch (error) {
        Log.w(TAG, `setSpeed skipped: ${(error as BusinessError).code}`);
      }
    }
  }

  async open(request: OpenRequest): Promise<Map<string, Object>> {
    this.volume = request.volume;
    this.rate = request.rate;
    // Signed media URLs stay out of logs; only the shape of the request is kept.
    Log.i(
      TAG,
      `open video=${request.videoUrl.length}B audio=${request.audioUrl !== null} ` +
        `headers=${request.videoHeaders !== null} start=${request.startPositionMs}ms`,
    );
    const video = await media.createAVPlayer();
    this.videoPlayer = video;
    this.bindEvents(video, true);
    await this.preparePlayer(
      video,
      request.videoUrl,
      request.videoHeaders,
      this.textureEntry.getSurfaceId().toString(),
    );
    if (request.audioUrl !== null) {
      const audio = await media.createAVPlayer();
      this.audioPlayer = audio;
      this.bindEvents(audio, false);
      await this.preparePlayer(audio, request.audioUrl, request.audioHeaders, null);
    }
    this.duration = video.duration > 0 ? video.duration : (this.audioPlayer?.duration ?? 0);
    this.applyVolume();
    this.applyRate();
    if (request.startPositionMs > 0) {
      await this.seek(request.startPositionMs);
    }
    const result = new Map<string, Object>();
    result.set('durationMs', this.duration);
    result.set('width', video.width);
    result.set('height', video.height);
    result.set('positionMs', this.currentPosition());
    return result;
  }

  currentPosition(): number {
    if (this.audioPlayer !== null) return this.audioPlayer.currentTime;
    return this.videoPlayer?.currentTime ?? 0;
  }

  async play(): Promise<void> {
    // play() is valid in prepared, paused and completed; a completed player
    // replays from its current position, which the caller has already seeked.
    // Seeking again here raced that seek and stalled playback.
    const players = this.players();
    const results: boolean[] = await Promise.all(
      players.map((player: media.AVPlayer) => this.attempt('play', () => player.play())),
    );
    if (results.length === 0 || !results.some((ran: boolean) => ran)) {
      throw new Error(`play failed (${this.players()
        .map((player: media.AVPlayer) => this.stateOf(player))
        .join(',')}) ${this.lastFailure}`);
    }
    this.playing = true;
  }

  async pause(): Promise<void> {
    // AVPlayer rejects pausing anything but a playing player, and the tracked
    // state can lag a command that just started playback. Request the pause on
    // every player and treat rejections as an already-paused no-op so a paused
    // video can never keep running because its state looked idle.
    const players = this.players();
    await Promise.all(
      players.map((player: media.AVPlayer) => this.attempt('pause', () => player.pause())),
    );
    this.playing = false;
  }

  async seek(positionMs: number): Promise<void> {
    const seeks: Promise<void>[] = [];
    if (this.videoPlayer !== null) seeks.push(this.seekPlayer(this.videoPlayer, positionMs));
    if (this.audioPlayer !== null) seeks.push(this.seekPlayer(this.audioPlayer, positionMs));
    await Promise.all(seeks);
    this.correcting = false;
    this.emit('position', positionMs);
  }

  async setRate(rate: number): Promise<void> {
    this.rate = rate;
    this.applyRate();
  }

  async setVolume(volume: number): Promise<void> {
    this.volume = volume;
    this.applyVolume();
  }

  async dispose(): Promise<void> {
    if (this.disposed) return;
    this.disposed = true;
    const video = this.videoPlayer;
    const audio = this.audioPlayer;
    this.videoPlayer = null;
    this.audioPlayer = null;
    this.states.clear();
    this.stateHandlers.clear();
    this.errorHandlers.clear();
    try {
      if (audio !== null) await audio.release();
    } catch (error) {
      Log.w(TAG, 'audio release failed');
    }
    try {
      if (video !== null) await video.release();
    } catch (error) {
      Log.w(TAG, 'video release failed');
    }
  }
}

function readNumber(call: MethodCall, key: string, fallback: number): number {
  const value: Any = call.argument(key);
  return typeof value === 'number' ? value as number : fallback;
}

function readString(call: MethodCall, key: string): string {
  const value: Any = call.argument(key);
  return typeof value === 'string' ? value as string : '';
}

function readHeaders(call: MethodCall, key: string): Record<string, string> | null {
  const value: Any = call.argument(key);
  if (value === null || value === undefined) return null;
  const headers: Record<string, string> = {};
  const map = value as Map<string, string>;
  map.forEach((headerValue: string, headerName: string) => {
    headers[headerName] = headerValue;
  });
  return Object.keys(headers).length === 0 ? null : headers;
}

export default class OhosAvPlayerPlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;
  private textureRegistry: TextureRegistry | null = null;
  private readonly sessions = new Map<number, AvSession>();
  private nextId: number = 1;

  getUniqueClassName(): string {
    return 'OhosAvPlayerPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.textureRegistry = binding.getTextureRegistry();
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
    this.sessions.forEach((session: AvSession) => {
      session.dispose();
    });
    this.sessions.clear();
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.textureRegistry = null;
  }

  private session(call: MethodCall): AvSession | null {
    const id = readNumber(call, 'id', -1);
    const session = this.sessions.get(id);
    return session === undefined ? null : session;
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      switch (call.method) {
        case 'create': {
          const registry = this.textureRegistry;
          const channel = this.channel;
          if (registry === null || channel === null) {
            result.error('unavailable', 'The Flutter engine is not attached.', null);
            return;
          }
          const textureId = registry.getTextureId();
          const entry = registry.registerTexture(textureId);
          const id = this.nextId++;
          this.sessions.set(id, new AvSession(id, entry, channel));
          const reply = new Map<string, Object>();
          reply.set('id', id);
          reply.set('textureId', textureId);
          result.success(reply);
          return;
        }
        case 'open': {
          const session = this.session(call);
          if (session === null) {
            result.error('missing', 'No such player.', null);
            return;
          }
          const request = new OpenRequest();
          request.videoUrl = readString(call, 'videoUrl');
          request.videoHeaders = readHeaders(call, 'videoHeaders');
          const audioUrl = readString(call, 'audioUrl');
          request.audioUrl = audioUrl.length > 0 ? audioUrl : null;
          request.audioHeaders = readHeaders(call, 'audioHeaders');
          request.startPositionMs = readNumber(call, 'startPositionMs', 0);
          request.rate = readNumber(call, 'rate', 1);
          request.volume = readNumber(call, 'volume', 100);
          result.success(await session.open(request));
          return;
        }
        case 'play':
        case 'pause':
        case 'seek':
        case 'setRate':
        case 'setVolume': {
          const session = this.session(call);
          if (session === null) {
            result.error('missing', 'No such player.', null);
            return;
          }
          if (call.method === 'play') await session.play();
          else if (call.method === 'pause') await session.pause();
          else if (call.method === 'seek') {
            await session.seek(readNumber(call, 'positionMs', 0));
          } else if (call.method === 'setRate') {
            await session.setRate(readNumber(call, 'rate', 1));
          } else {
            await session.setVolume(readNumber(call, 'volume', 100));
          }
          result.success(null);
          return;
        }
        case 'dispose': {
          const id = readNumber(call, 'id', -1);
          const session = this.sessions.get(id);
          if (session === undefined) {
            result.success(null);
            return;
          }
          this.sessions.delete(id);
          await session.dispose();
          this.textureRegistry?.unregisterTexture(session.getTextureId());
          result.success(null);
          return;
        }
        default:
          result.notImplemented();
      }
    } catch (error) {
      const failure = error as BusinessError;
      Log.e(
        TAG,
        `method ${call.method} failed: ${failure.code} ${failure.message} ${failure.stack ?? ''}`,
      );
      result.error('avplayer', failure.message === undefined ? 'native failure' : failure.message, null);
    }
  }
}
