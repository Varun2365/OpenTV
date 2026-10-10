// mpv-backed player. On Pi 4 + flutter-pi release builds, media_kit uses
// libmpv with V4L2M2M hardware decode — Flutter UI stays at 60fps because
// video never touches the Dart/Flutter texture rasterizer path heavily.
// On Windows dev machines it falls back to software decode automatically.
//
// Single-source-of-truth design: EVERYTHING (TV grid, keyboard, phone
// remote, D-pad) only calls AppState.play/stop. This service listens to the
// state and opens/stops mpv itself — so a channel change from the phone can
// never leave the previous channel's audio running under a stuck spinner.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/tv_channel.dart';
import 'app_state.dart';
import 'remote_command.dart';

class PlayerService {
  late final Player _player;
  late final VideoController _videoCtrl;
  AppState? _state;
  String? _currentId;
  int _openSeq = 0;
  Completer<void>? _prebufferDone;
  Tracks? _lastTracks;
  String? _videoOnlyId;
  DateTime _lastProgress = DateTime.now();
  Timer? _stallTimer;

  VideoController get videoController => _videoCtrl;
  Player get player => _player;

  Future<void> init(AppState state) async {
    _state = state;
    MediaKit.ensureInitialized();
    _player = Player(
      configuration: const PlayerConfiguration(
        // Deep buffer for jittery free sources: ride out stalls instead of
        // spinning on an 8MB window. Pi 4 has RAM to spare for this.
        bufferSize: 32 * 1024 * 1024,
        title: 'OpenTV-RPI',
      ),
    );
    _videoCtrl = VideoController(_player,
        configuration: const VideoControllerConfiguration(
          // HW decode on Linux (V4L2/VAAPI via mpv); keeps UI at 60fps.
          enableHardwareAcceleration: true,
        ));
    // Restore persisted settings: prebuffer tank (default 5s) and
    // hold-glide speed for the phone remote (default 6 keys/s).
    try {
      final prefs = await SharedPreferences.getInstance();
      state.setPrebufferSecs(
          prefs.getInt('opentv_prebuffer_secs') ?? 5);
      state.setRepeatRate(
          prefs.getInt('opentv_repeat_rate') ?? 6);
    } catch (_) {}
    // mpv demuxer/cache tuning for slow HLS origins. Best-effort per
    // property — unknown keys on some builds must never break playback.
    unawaited(_tuneMpv());
    // Remote transport keys -> player.
    state.keyStream.listen((k) {
      switch (k) {
        case RemoteKey.playPause:
          _player.playOrPause();
          break;
        case RemoteKey.volUp:
          _player.setVolume((_player.state.volume + 10).clamp(0, 100));
          break;
        case RemoteKey.volDown:
          _player.setVolume((_player.state.volume - 10).clamp(0, 100));
          break;
        case RemoteKey.mute:
          final v = _player.state.volume;
          _player.setVolume(v == 0 ? 80 : 0);
          break;
        default:
          break;
      }
    });
    _player.stream.playing.listen((playing) {
      state.setPlayingFlag(playing);
      if (playing) state.setPlayError(null);
    });
    _player.stream.buffering.listen((b) {
      if (!b) _lastProgress = DateTime.now(); // recovered counts too
      state.setBuffering(b);
    });
    _player.stream.bufferingPercentage.listen((p) {
      state.setBuffering(state.isBuffering, p);
    });
    _player.stream.width.listen((w) {
      if (w != null && w > 0) state.setHasVideo(true);
    });
    _player.stream.error.listen((msg) {
      final m = msg.trim();
      if (m.isEmpty) return;
      // mpv ALSO emits per-frame blips ("Error decoding audio/video") and
      // mid-stream network hiccups ("tcp: ffurl_read …", TLS resets,
      // timeouts) while playback rides through fine. Those must never nuke
      // the UI into an error card once we have picture or active playback
      // — only a pre-first-frame failure is fatal. A stall watchdog below
      // converts a truly dead connection into an error after 25 dry secs.
      final ml = m.toLowerCase();
      final blip = ml.contains('decoding audio') ||
          ml.contains('decoding video') ||
          ml.contains('ffurl_read') ||
          ml.contains('tcp:') ||
          ml.contains('tls') ||
          ml.contains('econnreset') ||
          ml.contains('connection reset') ||
          ml.contains('broken pipe') ||
          ml.contains('timed out') ||
          ml.contains('timeout') ||
          ml.contains('handshake') ||
          ml.contains('http error') ||
          ml.contains('failed to connect') ||
          ml.contains('unable to open connection');
      if (blip && (state.hasVideo || state.isPlaying)) {
        debugPrint('transient stream warning (ignored): $m');
        return;
      }
      state.setPlayError(m);
    });
    _player.stream.completed.listen((done) {
      if (done) state.setBuffering(false);
    });
    _player.stream.volume.listen((v) {
      state.setVolume(v / 100.0);
      state.setMuted(v == 0);
    });
    // HLS variant tracks → remote quality picker. Auto first, then
    // highest resolution first. The 'no' pseudo-track is UI poison.
    _player.stream.tracks.listen((t) {
      _lastTracks = t;
      final vids = t.video
          .where((v) => v.id != 'no')
          .toList()
        ..sort((a, b) {
          if (a.id == 'auto') return -1;
          if (b.id == 'auto') return 1;
          return (b.h ?? 0).compareTo(a.h ?? 0);
        });
      state.setVideoTracks(
          [for (final v in vids) _videoTrackJson(v)],
          state.selectedVideoTrack);
    });
    _player.stream.track.listen((t) {
      state.setVideoTracks(
          state.videoTracks, t.video.id);
    });
    // Stall watchdog: any arriving data resets the clock; 25 dry seconds
    // of buffering turns an infinite spinner into an actionable error.
    // (Prebuffer tank fills have their own N+20s deadline — this covers
    // mid-play connection deaths like ffurl_read drops.)
    _player.stream.buffer.listen((_) {
      _lastProgress = DateTime.now();
    });
    _stallTimer =
        Timer.periodic(const Duration(seconds: 5), (_) {
      final s = _state;
      if (s == null) return;
      if (s.playing == null ||
          s.playError != null ||
          !s.isBuffering ||
          s.prebuffering) {
        return;
      }
      if (DateTime.now()
              .difference(_lastProgress)
              .inSeconds >=
          25) {
        s.setPlayError(
            'The stream stalled — the server stopped sending data.');
      }
    });
    // State is the boss: any play/stop (TV, keyboard, phone) drives mpv.
    state.addListener(_syncWithState);
  }

  /// Push mpv cache/demuxer properties. Dynamic dispatch avoids a hard
  /// dependency on media_kit internals across versions.
  Future<void> _tuneMpv() async {
    await Future.delayed(const Duration(milliseconds: 500));
    try {
      final platform = _player.platform as dynamic;
      if (platform == null) return;
      // Keep ~20s of stream cached and read well ahead on HLS.
      // (Byte ceilings are set per-open by _setDemuxerCeiling so the
      // tank scales with N instead of hogging RAM at N=0.)
      await platform.setProperty('cache-secs', '20');
      await platform.setProperty(
          'demuxer-readahead-secs', '10');
      await platform.setProperty('network-timeout', '15');
      // Ask ffmpeg to transparently reconnect dropped HTTP/TCP segment
      // fetches (the ffurl_read family) instead of dying on first cut.
      await platform.setProperty('stream-lavf-o',
          'reconnect=1,reconnect_streamed=1,reconnect_delay_max=7');
    } catch (_) {}
  }

  static Map<String, dynamic> _videoTrackJson(
          VideoTrack t) =>
      {
        'id': t.id,
        'title': t.title ??
            ((t.h ?? 0) > 0 ? '${t.h}p' : t.id),
        'w': t.w,
        'h': t.h,
        'fps': t.fps,
        'bitrate': t.bitrate,
      };

  /// Manual quality selection from the phone remote ('auto' = mpv decides).
  Future<void> setQuality(String id) async {
    try {
      if (id == 'auto') {
        await _player.setVideoTrack(VideoTrack.auto());
      } else {
        VideoTrack? match;
        final vs = _lastTracks?.video;
        if (vs != null) {
          for (final v in vs) {
            if (v.id == id) {
              match = v;
              break;
            }
          }
        }
        await _player.setVideoTrack(
            match ?? VideoTrack(id, null, null));
      }
      final s = _state;
      if (s != null) {
        s.setVideoTracks(s.videoTracks, id);
      }
    } catch (e) {
      debugPrint('setQuality failed: $e');
    }
  }
  Future<void> _setDemuxerCeiling(int n) async {
    try {
      final platform = _player.platform as dynamic;
      if (platform == null) return;
      final cap = (n * 2 * 1024 * 1024)
          .clamp(32 * 1024 * 1024, 128 * 1024 * 1024);
      await platform.setProperty(
          'demuxer-max-bytes', '$cap');
      await platform.setProperty(
          'demuxer-max-back-bytes', '${cap ~/ 2}');
    } catch (_) {}
  }

  void _syncWithState() {
    final s = _state;
    if (s == null) return;
    final ch = s.playing;
    if (ch == null) {
      if (_currentId != null) {
        _currentId = null;
        _openSeq++; // cancel any in-flight open
        _player.stop();
      }
      return;
    }
    if (ch.id == _currentId) return; // already opening/open
    _currentId = ch.id;
    _lastProgress = DateTime.now(); // fresh stall clock per channel
    unawaited(_openChannel(ch));
  }

  Future<void> _openChannel(TvChannel ch) async {
    final seq = ++_openSeq;
    // Release any previous prebuffer waiter immediately — no orphaned
    // subscriptions/Timers holding stream references (memory discipline).
    _prebufferDone?.complete();
    _prebufferDone = null;
    try {
      final n = _state?.prebufferSecs ?? 0;
      await _setDemuxerCeiling(n);
      if (n > 0) {
        // Tank mode: open PAUSED, collect N seconds into mpv's cache,
        // then start — one initial wait instead of mid-play stutters.
        _state?.setPrebuffering(true, 0, n);
        await _player.open(Media(ch.streamUrl), play: false);
        await _applyVideoOnly(ch);
        if (seq != _openSeq) return; // zapped during open
        await _waitForPrebuffer(ch, n, seq);
      } else {
        // open() replaces the playlist: previous audio stops immediately,
        // new stream buffers under the loading overlay.
        await _player.open(Media(ch.streamUrl), play: true);
        await _applyVideoOnly(ch);
      }
    } catch (e) {
      if (seq != _openSeq) return; // superseded by a newer zap
      debugPrint('play failed ${ch.name}: $e');
      _state?.setPlayError(e.toString());
    }
  }

  /// Disables audio decoding for the video-only channel (chosen from the
  /// error card when a source's audio track is truly undecodable).
  Future<void> _applyVideoOnly(TvChannel ch) async {
    if (ch.id != _videoOnlyId) return;
    try {
      await _player.setAudioTrack(AudioTrack.no());
    } catch (_) {}
  }
  /// Wait until [n] seconds are cached (or N+20s elapse on trickling
  /// sources — then play whatever we have rather than hanging forever).
  Future<void> _waitForPrebuffer(
      TvChannel ch, int n, int seq) async {
    final s = _state;
    if (s == null) return;
    final target = Duration(seconds: n);
    final done = Completer<void>();
    _prebufferDone = done;
    Timer? deadline;
    deadline = Timer(Duration(seconds: n + 20), () {
      if (!done.isCompleted) done.complete();
    });
    StreamSubscription<Duration>? sub;
    sub = _player.stream.buffer.listen((buf) {
      if (seq != _openSeq ||
          s.playing?.id != ch.id ||
          s.playError != null) {
        if (!done.isCompleted) done.complete();
        return;
      }
      s.setPrebufferProgress(buf.inMilliseconds / 1000.0);
      if (buf >= target && !done.isCompleted) done.complete();
    }, onError: (_) {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    try {
      await sub.cancel();
    } catch (_) {}
    deadline.cancel();
    if (identical(_prebufferDone, done)) _prebufferDone = null;
    if (seq != _openSeq) return;
    if (s.playing?.id != ch.id || s.playError != null) return;
    s.setPrebuffering(false);
    try {
      await _player.play();
    } catch (e) {
      s.setPlayError(e.toString());
    }
  }

  /// Every entry point funnels here. Marks loading instantly; the state
  /// listener opens mpv (single path — no double-open, no orphan audio).
  /// A fresh normal play always restores audio (clears video-only mode).
  Future<void> playChannel(TvChannel ch) async {
    _videoOnlyId = null;
    _state?.play(ch);
  }

  /// Reopen the current channel with audio decoding disabled — escape hatch
  /// for sources whose audio track mpv genuinely cannot decode. The choice
  /// sticks to that channel until a fresh normal play from the TV grid.
  Future<void> retryVideoOnly() async {
    final ch = _state?.playing;
    if (ch == null) return;
    _videoOnlyId = ch.id;
    _currentId = null; // force reopen of the same channel
    _state?.play(ch);
  }

  Future<void> retryCurrent() async {
    final ch = _state?.playing;
    if (ch == null) return;
    _currentId = null; // force reopen of the same channel
    _state?.play(ch);
  }

  Future<void> toggle() => _player.playOrPause();
  Future<void> stop() async {
    _prebufferDone?.complete(); // release a waiting tank immediately
    _prebufferDone = null;
    _state?.stop(); // listener stops mpv; direct stop below is belt & braces
    await _player.stop();
  }

  Future<void> dispose() async {
    _stallTimer?.cancel();
    _stallTimer = null;
    _prebufferDone?.complete();
    _prebufferDone = null;
    _state?.removeListener(_syncWithState);
    await _player.dispose();
  }
}
