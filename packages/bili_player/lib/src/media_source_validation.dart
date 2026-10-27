import 'dart:io';

import 'player_contract.dart';

/// Tracks that have passed backend-independent option and header checks.
final class ValidatedMediaSource {
  const ValidatedMediaSource({required this.video, this.audio});

  final MediaTrack video;
  final MediaTrack? audio;
}

/// Validates options and tracks before a backend touches the source.
///
/// Every engine applies these rules, so a platform cannot silently accept
/// credentials or combinations that another backend rejects.
ValidatedMediaSource validateMediaSource(
  ResolvedMediaSource source,
  OpenOptions options,
  int generation,
) {
  final maxBufferAhead = options.maxBufferAhead;
  if (options.startPosition < Duration.zero ||
      !options.rate.isFinite ||
      options.rate <= 0 ||
      !options.volume.isFinite ||
      options.volume < 0 ||
      options.volume > 100 ||
      // Same bounds as NativeAudioGain.valid.
      !options.audioGainDb.isFinite ||
      options.audioGainDb < -60 ||
      options.audioGainDb > 30 ||
      options.openTimeout <= Duration.zero ||
      maxBufferAhead <= Duration.zero ||
      maxBufferAhead > OpenOptions.maximumBufferAhead) {
    throw PlayerFailure(
      PlayerFailureKind.invalidSource,
      'Invalid playback options.',
      generation,
    );
  }
  final MediaTrack media;
  MediaTrack? audio;
  switch (source) {
    case DashVideoSource(:final video):
      if (options.volume != 0) {
        throw PlayerFailure(
          PlayerFailureKind.invalidSource,
          'Video-only DASH requires a muted preview.',
          generation,
        );
      }
      return ValidatedMediaSource(video: _validateTrack(video, generation));
    case ProgressiveSource(:final media):
      return ValidatedMediaSource(video: _validateTrack(media, generation));
    case ManifestSource(:final media):
      return ValidatedMediaSource(video: _validateTrack(media, generation));
    case DashPairSource(
      video: final video,
      audio: final selectedAudio,
      isIntentionallySilent: final silent,
    ):
      media = _validateTrack(video, generation);
      if (selectedAudio == null && !silent) {
        throw PlayerFailure(
          PlayerFailureKind.invalidSource,
          'DASH audio track is missing.',
          generation,
        );
      }
      audio = selectedAudio == null
          ? null
          : _validateTrack(selectedAudio, generation);
      if (audio != null &&
          !_sameHeaders(
            media.requestPolicy.headers,
            audio.requestPolicy.headers,
          )) {
        throw PlayerFailure(
          PlayerFailureKind.unsupportedHeaders,
          'DASH tracks require different request headers.',
          generation,
        );
      }
      return ValidatedMediaSource(video: media, audio: audio);
  }
}

MediaTrack _validateTrack(MediaTrack track, int generation) {
  if (!{
        'http',
        'https',
        'file',
        if (Platform.isAndroid) 'content',
      }.contains(track.uri.scheme) ||
      track.uri.host.isEmpty && track.uri.scheme != 'file') {
    throw PlayerFailure(
      PlayerFailureKind.invalidSource,
      'Unsupported media URI.',
      generation,
    );
  }
  for (final entry in track.requestPolicy.headers.entries) {
    final name = entry.key.toLowerCase();
    if (!{'user-agent', 'referer', 'origin', 'accept'}.contains(name) ||
        entry.key.contains('\r') ||
        entry.key.contains('\n') ||
        entry.value.contains('\r') ||
        entry.value.contains('\n')) {
      throw PlayerFailure(
        PlayerFailureKind.unsupportedHeaders,
        'Unsupported media request header.',
        generation,
      );
    }
  }
  return track;
}

bool _sameHeaders(Map<String, String> left, Map<String, String> right) {
  Map<String, String> normalize(Map<String, String> value) => {
    for (final entry in value.entries) entry.key.toLowerCase(): entry.value,
  };

  final a = normalize(left);
  final b = normalize(right);
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
