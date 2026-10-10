// Dual-backend player.
//
// BACKGROUND (read before touching): flutter-pi is NOT the standard Flutter
// Linux embedder. It runs flutter_assets/ on its own KMS/DRM engine and never
// builds linux/runner — so NONE of the Linux plugin native code exists on the
// Pi (no media_kit_video TextureGL, no path_provider, ...). media_kit's Dart
// FFI to libmpv still demuxes (the "tank" fills from the demuxer cache), but
// video frames have nowhere to go: no Texture is ever registered, vo=gpu
// render fails, width/playing signals never resolve — hence the infinite
// "CONNECTING / Still connecting / struggling" on the Pi while Windows (full
// embedder + bundled libmpv + ANGLE textures) is fine.
//
// The official flutter-pi video path is video_player +
// flutterpi_gstreamer_video_player (gstreamer playbin, HW decode, inline
// texture that flutter-pi DOES implement). So:
//   - Desktop (Windows / standard Linux): media_kit backend (unchanged).
//   - flutter-pi (see pi_detector.dart): gstreamer backend via video_player.
// Selection is automatic at init(); override with --dart-define=OPENTV_PI
// (force Pi) / OPENTV_FORCE_MPV (force mpv) or env OPENTV_PI=1.
//
// Single-source-of-truth design (both backends): EVERYTHING (TV grid,
// keyboard, phone remote, D-pad) only calls AppState.play/stop. This service
// listens to the state and opens/stops the active backend itself — so a
// channel change from the phone can never leave the previous channel's audio
// running under a stuck spinner.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutterpi_gstreamer_video_player/flutterpi_gstreamer_video_player.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    hide VideoTrack;

import '../models/tv_channel.dart';
import 'app_state.dart';
import 'pi_detector.dart';
import 'remote_command.dart';

class PlayerService extends ChangeNotifier {
  // Active backend. Decided once in init() so a device never flip-flops
  // mid-session (which would orphan a controller + its audio).
  bool _piMode = false;
  bool get isPiMode => _piMode;

  // ---- mpv backend (desktop) ----
  Player? _player;
  VideoController? _videoCtrl;

  /// mpv video controller. Null on the Pi (gstreamer backend owns the
  /// picture there). PlayerScreen branches on [isPiMode] — never touch this
  /// when [_piMode] is true.
  VideoController? get videoController => _videoCtrl;

  /// Raw mpv player. Null on the Pi.
  Player? get player => _player;

  // ---- gstreamer backend (flutter-pi) ----
  VideoPlayerController? _piCtrl;
  int _piSeq = 0;

  /// Active Pi controller. Null on desktop OR while nothing is opening.
  /// PlayerScreen listens to this service (ChangeNotifier) so controller
  /// swaps rebuild the VideoPlayer widget.
  VideoPlayerController? get piController => _piCtrl;

  AppState? _state;
  String? _currentId;
  int _openSeq = 0;
  Completer<void>? _prebufferDone;
  Tracks? _lastTracks;
  String? _videoOnlyId;
  DateTime _lastProgress = DateTime.now();
  Duration _lastPosition = Duration.zero;
  Timer? _stallTimer;
  Timer? _loadWatchdog;
  // Pi freeze detection: our own 2s position poll (see _piPollTick) is the
  // ONLY flow signal — video_player's 100ms poll never starts because we
  // never call controller.play()/pause() on Pi (see _piPlayRaw). Static
  // position + isPlaying + first frame on screen = wedged pipeline (stuck
  // preroll / starved live edge); a throwing poll = dead pipeline
  // (GST_STATE_CHANGE_FAILURE). _piPollTick recovers (re-kick, then fresh
  // reopen) instead of showing one frame forever. Costs nothing when
  // healthy: one native query per 2s plus timestamps + ints.
  Timer? _piPollTimer;
  DateTime _lastFlowAt = DateTime.now();
  double _lastBufferedEnd = 0;
  // True once ANY flow signal (position or buffered-end) has moved on the
  // current pipeline. Until then the stream is UNKNOWN, never frozen: some
  // backends report neither signal during healthy playback, and punishing
  // that with re-kicks murders working streams.
  bool _signalEverMoved = false;
  int _flowStrikes = 0;
  DateTime _lastRecoveryAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  // Death memory: a pipeline that dies twice within 90s means the SERVER
  // is throttling/blocking us after the reconnect burst (typical on free
  // panel URLs) — not a wedged client. Survives reopens (reset only on a
  // manual zap) so the ladder can't hammer a server that's saying no.
  DateTime _lastDeathAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  // Set when the watchdog (not the user) triggers a reopen, so _syncWithState
  // preserves the ladder instead of resetting it as a fresh zap would.
  bool _autoReopen = false;
  // The ladder contains awaits (breather delay); never run two at once.
  bool _flowBusy = false;
  bool _disposed = false;

  Future<void> init(AppState state) async {
    _state = state;
    _piMode = isFlutterPi;
    debugPrint('PlayerService: backend='
        '${_piMode ? 'gstreamer(video_player/flutter-pi)' : 'mpv(media_kit)'}');

    // Restore persisted settings: prebuffer tank (default 5s),
    // hold-glide speed (default 6 keys/s), QR auto-show + preset
    // categories (both default on). try/catch: on flutter-pi the
    // shared_preferences MethodChannel has no native side, so this just
    // keeps in-session defaults instead of crashing boot.
    try {
      final prefs = await SharedPreferences.getInstance();
      state.setPrebufferSecs(
          prefs.getInt('opentv_prebuffer_secs') ?? 5);
      state.setRepeatRate(
          prefs.getInt('opentv_repeat_rate') ?? 6);
      state.setAutoQr(
          prefs.getBool('opentv_auto_qr') ?? true);
      state.setStretchVideo(
          prefs.getBool('opentv_stretch') ?? false);
      state.setShowPresets(
          prefs.getBool('opentv_show_presets') ?? true);
    } catch (e) {
      debugPrint('PlayerService: prefs unavailable ($e) — defaults kept');
    }

    if (_piMode) {
      _initPi(state);
    } else {
      await _initMpv(state);
    }

    // Remote transport keys -> active backend.
    state.keyStream.listen((k) {
      switch (k) {
        case RemoteKey.playPause:
          toggle();
          break;
        case RemoteKey.volUp:
          _bumpVolume(10);
          break;
        case RemoteKey.volDown:
          _bumpVolume(-10);
          break;
        case RemoteKey.mute:
          _toggleMute();
          break;
        default:
          break;
      }
    });
    // Stall watchdog: any arriving data resets the clock; 25 dry seconds
    // of buffering turns an infinite spinner into an actionable error.
    // (Prebuffer tank fills have their own N+20s deadline — this covers
    // mid-play connection deaths like ffurl_read drops.)
    _player?.stream.buffer.listen((_) {
      _lastProgress = DateTime.now();
    });
    _stallTimer =
        Timer.periodic(const Duration(seconds: 5), (_) {
      final s = _state;
      if (s == null || _disposed) return;
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
    // Absolute load cap (both backends): a spinner that outlives 90s is a
    // hung backend, not a slow network (tank deadline is N+20s <= 50s).
    // Convert it into an actionable error card instead of "CONNECTING…"
    // forever. Prebuffering with advancing progress is exempt while it
    // advances (covered by its own deadline + this exempts recent progress).
    _loadWatchdog =
        Timer.periodic(const Duration(seconds: 5), (_) {
      final s = _state;
      if (s == null || _disposed) return;
      if (s.playing == null || s.playError != null) return;
      final loading =
          s.isBuffering || !s.hasVideo || s.prebuffering;
      if (!loading) return;
      final elapsed =
          DateTime.now().difference(s.playRequestedAt).inSeconds;
      final progressing = DateTime.now()
              .difference(_lastProgress)
              .inSeconds <
          10;
      if (elapsed >= 90 && !progressing) {
        debugPrint('PlayerService: load watchdog fired after ${elapsed}s '
            '(backend=${_piMode ? 'gstreamer' : 'mpv'}, '
            'buffering=${s.isBuffering} hasVideo=${s.hasVideo} '
            'prebuffering=${s.prebuffering})');
        s.setPlayError(_piMode
            ? 'No picture arrived — the Pi decoder may lack this format or the link died. Retry, or pick a green-dot channel.'
            : 'Still no picture after 90s — the link is likely dead. Retry, or pick a green-dot channel.');
      }
    });
    // Pi flow poll (2s): position source + freeze/death recovery. Desktop
    // mpv self-recovers via reconnect + stall logic, so Pi-only.
    if (_piMode) {
      _piPollTimer =
          Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_piPollTick());
      });
    }
    // State is the boss: any play/stop (TV, keyboard, phone) drives the
    // active backend (single path — no double-open, no orphan audio).
    state.addListener(_syncWithState);
  }

  // ================= mpv backend (desktop) =================

  Future<void> _initMpv(AppState state) async {
    try {
      MediaKit.ensureInitialized();
    } catch (e) {
      debugPrint('PlayerService: MediaKit init failed: $e');
      state.setPlayError('Video engine failed to start: $e');
      return;
    }
    final player = Player(
      configuration: const PlayerConfiguration(
        // Deep buffer for jittery free sources: ride out stalls instead of
        // spinning on an 8MB window. Pi 4 has RAM to spare for this.
        bufferSize: 32 * 1024 * 1024,
        title: 'OpenTV-RPI',
      ),
    );
    _player = player;
    _videoCtrl = VideoController(player,
        configuration: const VideoControllerConfiguration(
          // HW decode on Linux (V4L2/VAAPI via mpv); keeps UI at 60fps.
          enableHardwareAcceleration: true,
        ));
    // mpv demuxer/cache tuning for slow HLS origins. Best-effort per
    // property — unknown keys on some builds must never break playback.
    unawaited(_tuneMpv());
    player.stream.playing.listen((playing) {
      state.setPlayingFlag(playing);
      if (playing) state.setPlayError(null);
    });
    player.stream.buffering.listen((b) {
      if (!b) _lastProgress = DateTime.now(); // recovered counts too
      state.setBuffering(b);
    });
    player.stream.bufferingPercentage.listen((p) {
      state.setBuffering(state.isBuffering, p);
    });
    // First-frame signals. width/height come from mpv video params; tracks
    // is the fallback — some builds emit tracks without size events, and
    // without ANY of these the UI spins forever ("still connecting").
    player.stream.width.listen((w) {
      if (w != null && w > 0) state.setHasVideo(true);
    });
    player.stream.height.listen((h) {
      if (h != null && h > 0) state.setHasVideo(true);
    });
    player.stream.error.listen((msg) {
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
    player.stream.completed.listen((done) {
      if (done) state.setBuffering(false);
    });
    player.stream.volume.listen((v) {
      state.setVolume(v / 100.0);
      state.setMuted(v == 0);
    });
    // HLS variant tracks → remote quality picker. Auto first, then
    // highest resolution first. The 'no' pseudo-track is UI poison.
    player.stream.tracks.listen((t) {
      _lastTracks = t;
      final vids = t.video
          .where((v) => v.id != 'no')
          .toList()
        ..sort((a, b) {
          if (a.id == 'auto') return -1;
          if (b.id == 'auto') return 1;
          return (b.h ?? 0).compareTo(a.h ?? 0);
        });
      // A listed video track with dimensions IS first-frame evidence
      // (covers builds that skip width/height events).
      for (final v in vids) {
        if ((v.w ?? 0) > 0 || (v.h ?? 0) > 0) {
          state.setHasVideo(true);
          break;
        }
      }
      state.setVideoTracks(
          [for (final v in vids) _videoTrackJson(v)],
          state.selectedVideoTrack);
    });
    player.stream.track.listen((t) {
      state.setVideoTracks(
          state.videoTracks, t.video.id);
    });
  }

  /// Push mpv cache/demuxer properties. Dynamic dispatch avoids a hard
  /// dependency on media_kit internals across versions.
  Future<void> _tuneMpv() async {
    final player = _player;
    if (player == null) return;
    await Future.delayed(const Duration(milliseconds: 500));
    try {
      final platform = player.platform as dynamic;
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
  /// On the Pi (gstreamer playbin) there is no per-variant API — playbin
  /// auto-selects, so this is a logged no-op there.
  Future<void> setQuality(String id) async {
    if (_piMode) {
      debugPrint('setQuality($id) ignored on Pi backend (playbin auto)');
      return;
    }
    try {
      final player = _player;
      if (player == null) return;
      if (id == 'auto') {
        await player.setVideoTrack(VideoTrack.auto());
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
        await player.setVideoTrack(
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
      final platform = _player?.platform as dynamic;
      if (platform == null) return;
      final cap = (n * 2 * 1024 * 1024)
          .clamp(32 * 1024 * 1024, 128 * 1024 * 1024);
      await platform.setProperty(
          'demuxer-max-bytes', '$cap');
      await platform.setProperty(
          'demuxer-max-back-bytes', '${cap ~/ 2}');
    } catch (_) {}
  }

  // ================= gstreamer backend (flutter-pi) =================

  void _initPi(AppState state) {
    // Volume state starts at the AppState default; the controller pushes
    // real values once it initializes.
    debugPrint('PlayerService: Pi backend ready — '
        'ensure flutter-pi was rebuilt with gstreamer support and the Pi '
        'has gstreamer1.0-plugins-{base,good,bad,ugly,libav} installed.');
  }

  /// Seek-free play/pause for the Pi backend. VideoPlayerController.play()
  /// silently runs seekTo(0) whenever value.position == value.duration —
  /// routine for live HLS with degenerate durations — and a flush-seek at 0
  /// wedges live pipelines (native "Could not set the new playback speed /
  /// playback position" → GST_STATE_CHANGE_FAILURE → EIO storm). The two
  /// platform calls below are exactly what play()/pause() do minus the seek
  /// (verified against the video_player 2.11 source); value sync is manual,
  /// and our own poll (never the 100ms timer) tracks position. playerId is
  /// visibleForTesting upstream — the VideoPlayer widget itself uses it.
  Future<void> _piPlayRaw(VideoPlayerController c) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final id = c.playerId;
    c.value = c.value.copyWith(isPlaying: true);
    await VideoPlayerPlatform.instance.play(id);
  }

  Future<void> _piPauseRaw(VideoPlayerController c) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final id = c.playerId;
    c.value = c.value.copyWith(isPlaying: false);
    await VideoPlayerPlatform.instance.pause(id);
  }

  void _onPiUpdate() {
    final s = _state;
    final c = _piCtrl;
    if (s == null || c == null) return;
    if (!c.value.isInitialized) return;
    final v = c.value;
    // First-frame evidence: initialized + sized frame.
    if (v.size.width > 0 && v.size.height > 0) {
      s.setHasVideo(true);
    }
    // Buffering + playing flags drive the overlay / pill.
    final wasBuffering = s.isBuffering;
    s.setBuffering(v.isBuffering);
    if (v.isPlaying != s.isPlaying) s.setPlayingFlag(v.isPlaying);
    if (v.isPlaying || !v.isBuffering) {
      _lastProgress = DateTime.now();
    } else if (!wasBuffering && v.isBuffering) {
      // entered buffering — keep old progress clock (watchdog measures
      // dry time), don't reset.
    }
    // NOTE: position tracking lives in _piPollTick (our own 2s poll), not
    // here — without controller.play() there are no position events, and
    // the poll is the single source of truth for flow/death.
    if (v.hasError) {
      final desc = (v.errorDescription ?? '').trim();
      if (desc.isNotEmpty) {
        debugPrint('Pi player error: $desc');
        s.setPlayError(desc);
      }
    }
  }

  double _piBufferedEnd() {
    final c = _piCtrl;
    if (c == null) return 0;
    try {
      var end = 0.0;
      for (final r in c.value.buffered) {
        final e = r.end.inMilliseconds / 1000.0;
        if (e > end) end = e;
      }
      return end;
    } catch (_) {
      return 0;
    }
  }

  /// Pi poll tick (every 2s): the ONLY flow judge. We never call
  /// controller.play()/pause() on Pi (see _piPlayRaw), so video_player's
  /// 100ms poll never starts — this try/catch-guarded probing replaces it
  /// at a Pi-friendly cadence. Flow is multi-signal: a moving POSITION or a
  /// moving BUFFERED-END each prove motion (tank path reports ranges, stock
  /// may report neither). A stream with no moving signal is UNKNOWN, never
  /// frozen — recovery would murder healthy playback. Only a throwing poll
  /// (PlatformException = GST_STATE_CHANGE_FAILURE) proves DEATH, and death
  /// pauses first (raw, seek-free) so nothing interrogates the corpse.
  /// Recovery ladder: raw re-kick for proven-frozen (cheap, never seeks),
  /// straight to reopen for dead, breather before reconnecting, honest card
  /// at the cap, 90s re-death backoff against throttling servers. Resets on
  /// motion or manual zap. Zero allocation while healthy.
  Future<void> _piPollTick() async {
    if (_disposed || !_piMode) return;
    final s = _state;
    if (s == null) return;
    final ch = s.playing;
    if (ch == null || s.playError != null || s.prebuffering) return;
    if (!s.hasVideo) return; // no first frame yet — not frozen, just loading
    final c = _piCtrl;
    if (c == null) return;
    try {
      if (!c.value.isInitialized || !c.value.isPlaying) return;
    } catch (_) {
      return; // controller gone mid-check
    }
    // Liveness probes + flow clocks, in try/catch by design. A moving
    // position OR a moving buffered-end each prove the pipeline flows.
    var dead = false;
    try {
      final pos = await c.position;
      if (!identical(_piCtrl, c) || s.playing?.id != ch.id) return;
      if (pos != null && pos != _lastPosition) {
        _lastPosition = pos;
        _lastProgress = DateTime.now();
        _lastFlowAt = DateTime.now();
        _flowStrikes = 0;
        _signalEverMoved = true;
      }
    } on PlatformException catch (e) {
      dead = true;
      debugPrint('Pi poll: pipeline dead ($e)');
    } catch (_) {}
    // Second flow signal: buffered-end advance. The tank pipeline's queue2
    // reports real ranges; stock reports none. Either signal independently
    // proves motion (and clears strikes).
    try {
      final end = _piBufferedEnd();
      if (end > 0 && end - _lastBufferedEnd > 0.25) {
        _lastBufferedEnd = end;
        _lastProgress = DateTime.now();
        _lastFlowAt = DateTime.now();
        _flowStrikes = 0;
        _signalEverMoved = true;
      }
    } catch (_) {}
    if (!identical(_piCtrl, c) || s.playing?.id != ch.id) return;
    if (s.playError != null) return;
    if (dead) {
      try {
        await _piPauseRaw(c);
      } catch (_) {} // park it; nothing else should touch the corpse
      if (DateTime.now().difference(_lastDeathAt).inSeconds < 90) {
        debugPrint('Pi poll: re-died within 90s, '
            'backing off (${ch.name})');
        s.setPlayError(
            'The server stopped serving this stream (throttled or expired link). Wait a bit, then retry — or pick another channel.');
        return;
      }
      _lastDeathAt = DateTime.now();
    } else {
      if (DateTime.now().difference(_lastFlowAt).inSeconds < 8) return;
      if (!_signalEverMoved) return; // UNKNOWN, not frozen: this backend
      // reports no moving signal during healthy playback — recovery here
      // would murder a working stream (re-kicks interrupt motion, reopens
      // hammer the server). Only proven DEATH recovers, above.
    }
    if (DateTime.now().difference(_lastRecoveryAt).inSeconds <
        (dead ? 5 : 15)) {
      return; // cooling down from the last attempt
    }
    if (_flowBusy) return;
    _flowBusy = true;
    try {
      final seq = _piSeq;
      // Failed pipelines skip re-kicks and jump to reopen; frozen ones
      // climb the ladder.
      _flowStrikes += dead ? 3 : 1;
      _lastRecoveryAt = DateTime.now();
      if (_flowStrikes <= 2) {
        // Cheap raw re-kick: re-issue the state change with zero seeks.
        // Fixes pipelines stuck between PAUSED preroll and PLAYING.
        debugPrint('Pi poll: picture frozen, '
            're-kick #$_flowStrikes (${ch.name})');
        await _piPauseRaw(c);
        await Future.delayed(
            const Duration(milliseconds: 400));
        if (seq != _piSeq || _disposed) return;
        if (s.playing?.id != ch.id || s.playError != null) return;
        if (!identical(_piCtrl, c)) return;
        await _piPlayRaw(c);
        _lastFlowAt = DateTime.now();
      } else if (_flowStrikes <= 4) {
        // Fresh pipeline at the live edge — the only cure for a failed or
        // wedged Bin. Breather first when dead: the server just watched a
        // pipeline die. Same single path as a manual retry — old controller
        // disposed first, so no stacking, no audio leak, no memory growth.
        if (dead) {
          await Future.delayed(const Duration(seconds: 5));
          if (seq != _piSeq || _disposed) return;
          if (s.playing?.id != ch.id || s.playError != null) return;
        }
        debugPrint('Pi poll: reopening '
            '#$_flowStrikes (${ch.name})');
        _autoReopen = true; // preserve the ladder across the reopen
        _lastFlowAt = DateTime.now();
        _currentId = null; // force reopen of the same channel
        s.play(ch);
      } else {
        debugPrint('Pi poll: giving up after $_flowStrikes '
            'attempts (${ch.name})');
        s.setPlayError(
            'This stream keeps freezing on the Pi — retry later, or pick a green-dot channel.');
      }
    } catch (e) {
      debugPrint('Pi flow recovery failed: $e');
    } finally {
      _flowBusy = false;
    }
  }

  static bool _isHlsUrl(String url) =>
      url.toLowerCase().contains('.m3u8');

  /// Tank pipeline: an explicit, observable bank ahead of the decoder.
  /// uridecodebin (the stock path) hides small internal queues and never
  /// answers GST_QUERY_BUFFERING, so Dart can neither see nor size any bank
  /// there. Here queue2 (a) banks [bankSecs] of media, absorbing segment
  /// jitter and slow origins, and (b) answers buffering queries, so buffered
  /// ranges + buffering start/end events reach Dart and the tank bar,
  /// rebuffer pill and watchdogs become REAL instead of proxies. decodebin
  /// (not a fixed codec chain) keeps H264/HEVC/etc. working; videoconvert
  /// lands decoder output in the EGL-uploadable formats appsink accepts. No
  /// audio branch — same as stock (Pi audio is a separate step). Only the
  /// element named "sink" is required by the native side; nothing is named
  /// "src" on purpose, so the native uri/headers/element-added hooks (built
  /// for uridecodebin) leave this chain untouched.
  static String _piTankPipeline(String url, int bankSecs) {
    final loc = url.replaceAll('"', '%22');
    final bankNs = bankSecs * 1000000000;
    const queue =
        'queue2 max-size-buffers=0 max-size-bytes=0 max-size-time={NS} use-buffering=true';
    final q = queue.replaceAll('{NS}', '$bankNs');
    final head = _isHlsUrl(url)
        ? 'souphttpsrc location="$loc" ! hlsdemux ! $q'
        : 'souphttpsrc location="$loc" ! $q';
    return '$head ! decodebin ! videoconvert ! appsink name=sink sync=true';
  }

  Future<void> _openPiChannel(TvChannel ch, int seq) async {
    final s = _state;
    if (s == null) return;
    // Tear down the previous controller FIRST (single path — previous
    // audio can never leak under the new spinner).
    final old = _piCtrl;
    _piCtrl = null;
    if (old != null) {
      try {
        old.removeListener(_onPiUpdate);
      } catch (_) {}
      try {
        await _piPauseRaw(old);
      } catch (_) {}
      try {
        await old.dispose();
      } catch (_) {}
    }
    notifyListeners(); // VideoPlayer widget drops the old texture now

    final n = s.prebufferSecs;
    // Bank sizing: the explicit queue2 holds bankSecs of media ahead of the
    // decoder. Scales with the user's tank setting, bounded so one channel
    // never dedicates silly RAM (~2-8 Mbps → 15s ≈ 4-15MB, 60s ≈ 60MB max).
    final bankSecs = (n * 4).clamp(15, 60);
    VideoPlayerController ctrl;
    var tankPath = false;
    // Attempt 1: tank pipeline (explicit bank + observable ranges).
    // Attempt 2 (on failure): stock uridecodebin path (proven to play).
    // Per-channel fallback — a chain the decoder dislikes degrades
    // gracefully instead of killing the tune.
    try {
      debugPrint(
          'Pi open: tank pipeline (${ch.name}, bank=${bankSecs}s)');
      ctrl = FlutterpiVideoPlayerController.withGstreamerPipeline(
        _piTankPipeline(ch.streamUrl, bankSecs),
        formatHint:
            _isHlsUrl(ch.streamUrl) ? VideoFormat.hls : null,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      tankPath = true;
      _piCtrl = ctrl;
      ctrl.addListener(_onPiUpdate);
      notifyListeners();
      await ctrl.initialize().timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('Pi tank pipeline failed (${ch.name}): $e — '
          'falling back to stock path');
      final failed = _piCtrl;
      if (failed != null) {
        try {
          failed.removeListener(_onPiUpdate);
        } catch (_) {}
        try {
          await failed.dispose();
        } catch (_) {}
        if (identical(_piCtrl, failed)) _piCtrl = null;
      }
      tankPath = false;
      if (seq != _piSeq || _disposed) return;
      if (s.playing?.id != ch.id || s.playError != null) return;
      // Missing native plugin fails BOTH paths identically — say so once
      // instead of running the stock attempt into the same wall.
      if (e is MissingPluginException ||
          '$e'.contains('gstreamerVideoPlayer')) {
        notifyListeners();
        s.setPlayError(
            'This flutter-pi has no video plugin — rebuild flutter-pi with gstreamer support, then restart the app.');
        return;
      }
      try {
        debugPrint('Pi open: stock path (${ch.name})');
        ctrl = VideoPlayerController.networkUrl(
          Uri.parse(ch.streamUrl),
          formatHint:
              _isHlsUrl(ch.streamUrl) ? VideoFormat.hls : null,
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
        );
        _piCtrl = ctrl;
        ctrl.addListener(_onPiUpdate);
        notifyListeners();
        await ctrl.initialize().timeout(const Duration(seconds: 25));
      } catch (e2) {
        final failed2 = _piCtrl;
        if (failed2 != null) {
          try {
            failed2.removeListener(_onPiUpdate);
          } catch (_) {}
          try {
            await failed2.dispose();
          } catch (_) {}
          if (identical(_piCtrl, failed2)) _piCtrl = null;
        }
        if (seq != _piSeq || _disposed) return;
        notifyListeners();
        debugPrint(
            'Pi init failed ${ch.name}: both pipelines failed ($e2)');
        s.setPlayError(
            'The Pi could not open this stream (format or network). Retry, or pick a green-dot channel.');
        return;
      }
    }
    if (seq != _piSeq || _disposed) return;
    if (s.playing?.id != ch.id || s.playError != null) return;
    debugPrint('Pi open: ${tankPath ? 'tank' : 'stock'} path live '
        '(${ch.name})');

    _lastProgress = DateTime.now();
    _lastPosition = Duration.zero;
    _lastFlowAt = DateTime.now(); // fresh freeze clock per open
    _lastBufferedEnd = 0; // fresh signal state per open
    _signalEverMoved = false;
    // NOTE: _flowStrikes / _lastDeathAt deliberately NOT reset here — this
    // runs for auto-reopens too, and the ladder must survive them (it
    // resets on manual zaps in _syncWithState and on flow in _onPiUpdate).
    s.setHasVideo(
        ctrl.value.size.width > 0 && ctrl.value.size.height > 0);

    // LIVE-SAFE START: play immediately, never hold a live HLS pipeline
    // paused. A paused-then-resumed live pipeline restarts behind the live
    // edge — if those segments slid out of the playlist window the demuxer
    // wedges (plays ~one segment / 3-4s, then freezes; long holds error
    // outright). The OVERLAY does the waiting instead: it clears on first
    // frame + observed flow + a short dwell, so the reveal is stable but
    // the pipeline never goes stale. (Desktop mpv keeps its paused tank —
    // mpv's cache handles live-resume correctly.)
    try {
      await ctrl.setVolume(s.muted ? 0 : s.volume.clamp(0.0, 1.0));
    } catch (_) {}
    final playAt = DateTime.now();
    try {
      await _piPlayRaw(ctrl); // raw: no implicit seekTo(0) on live streams
    } catch (e) {
      s.setPlayError('Could not start playback ($e).');
      return;
    }
    _lastProgress = DateTime.now();
    _lastFlowAt = DateTime.now();

    if (n > 0) {
      // Reveal gate (was: paused tank). Same overlay UX — "Filling tank…
      // Xs/Ns" — but the picture warms up behind the veil instead of the
      // pipeline sitting paused. Clears on flow; the N+20s backstop with no
      // observed flow becomes an error, never a dead-frame reveal.
      s.setPrebuffering(true, 0, n);
      final dwell = n.clamp(0, 6); // live can't bank: long waits go stale
      final deadline = playAt.add(Duration(seconds: n + 20));
      var lastPush = -1.0;
      var revealed = false;
      while (DateTime.now().isBefore(deadline)) {
        if (seq != _piSeq || _disposed) return;
        if (s.playing?.id != ch.id || s.playError != null) return;
        final elapsed =
            DateTime.now().difference(playAt).inSeconds;
        // Progress: real buffered ranges when the backend reports them
        // (tank pipeline's queue2 answers buffering queries; the stock
        // path never does — that's the native "Could not query buffering
        // state" spam, harmless). Falls back to a flow-observed proxy so
        // the bar never sits at 0s.
        final end = _piBufferedEnd();
        final shown =
            end > 0 ? end : elapsed.clamp(0, n).toDouble();
        if ((shown - lastPush).abs() >= 0.5) {
          lastPush = shown;
          s.setPrebufferProgress(shown);
        }
        // Progress counts — the load watchdog must not fire mid-warmup.
        if (end > 0) _lastProgress = DateTime.now();
        // Reveal: first frame + recently-observed flow + dwell elapsed.
        // Unknown-escape: if no signal has EVER moved, flow is unprovable
        // on this backend — reveal on dwell+margin rather than holding the
        // veil forever (proven death still errors via the poll + the
        // backstop below).
        final flowing = DateTime.now()
                .difference(_lastFlowAt)
                .inSeconds <
            3;
        final unknown = !_signalEverMoved;
        final escapeAt = dwell < 8 ? 8 : dwell;
        if (s.hasVideo &&
            ((flowing && elapsed >= dwell) ||
                (unknown && elapsed >= escapeAt))) {
          revealed = true;
          break;
        }
        await Future.delayed(
            const Duration(milliseconds: 250));
      }
      if (seq != _piSeq || _disposed) return;
      if (s.playing?.id != ch.id || s.playError != null) return;
      s.setPrebuffering(false);
      if (!revealed) {
        // Backstop hit with no observed flow — surface it instead of
        // lifting the veil onto a dead frame. The freeze watchdog below
        // keeps working the stream if it later moves.
        s.setPlayError(
            'The stream connected but no picture flowed — retry, or pick a green-dot channel.');
        return;
      }
    }
    _lastProgress = DateTime.now();
    // First-frame watchdog: playing but no sized frame within 20s means
    // the decoder can't produce pictures (missing gstreamer plugin /
    // unsupported codec) — say so instead of spinning forever.
    unawaited(Future.delayed(const Duration(seconds: 20), () {
      if (_disposed) return;
      final st = _state;
      if (st == null) return;
      if (seq != _piSeq) return;
      if (st.playing?.id != ch.id || st.playError != null) return;
      if (!st.hasVideo) {
        debugPrint('Pi first-frame watchdog: no sized frame 20s after play '
            '(buffered=${_piBufferedEnd().toStringAsFixed(1)}s). '
            'Hint: sudo apt install gstreamer1.0-plugins-{base,good,bad,ugly,libav} '
            'and rebuild flutter-pi with gstreamer support.');
        st.setPlayError(
            "The Pi fetched the stream but no picture arrived — likely a missing decoder (run: sudo apt install gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav). Or pick a green-dot channel.");
      }
    }));
  }

  // ================= shared sync =================

  void _syncWithState() {
    final s = _state;
    if (s == null || _disposed) return;
    final ch = s.playing;
    if (ch == null) {
      if (_currentId != null) {
        _currentId = null;
        _openSeq++; // cancel any in-flight mpv open
        _piSeq++; // cancel any in-flight Pi open
        if (_piMode) {
          unawaited(_teardownPi());
        } else {
          try {
            _player?.stop();
          } catch (_) {}
        }
      }
      return;
    }
    if (ch.id == _currentId) return; // already opening/open
    final isAuto = _autoReopen; // watchdog-driven reopen, not a fresh zap
    _autoReopen = false;
    _currentId = ch.id;
    _lastProgress = DateTime.now(); // fresh stall clock per channel
    _lastFlowAt = DateTime.now(); // fresh freeze clock per channel
    _lastBufferedEnd = 0; // fresh signal state per channel
    _signalEverMoved = false;
    if (!isAuto) {
      // Manual zap: reset the ladder + death memory. Auto-reopens preserve
      // both so a chronically dying stream still reaches the cap + backoff.
      _flowStrikes = 0;
      _lastDeathAt = DateTime.fromMillisecondsSinceEpoch(0);
    }
    if (_piMode) {
      final seq = ++_piSeq;
      _openSeq = seq;
      unawaited(_openPiChannel(ch, seq));
    } else {
      unawaited(_openChannel(ch));
    }
  }

  Future<void> _teardownPi() async {
    final old = _piCtrl;
    _piCtrl = null;
    if (old != null) {
      try {
        old.removeListener(_onPiUpdate);
      } catch (_) {}
      try {
        await _piPauseRaw(old);
      } catch (_) {}
      try {
        await old.dispose();
      } catch (_) {}
    }
    try {
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _openChannel(TvChannel ch) async {
    final player = _player;
    if (player == null) {
      _state?.setPlayError(
          'Video engine is not ready — restart the app.');
      return;
    }
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
        await player.open(Media(ch.streamUrl), play: false);
        await _applyVideoOnly(ch);
        if (seq != _openSeq) return; // zapped during open
        await _waitForPrebuffer(ch, n, seq);
      } else {
        // open() replaces the playlist: previous audio stops immediately,
        // new stream buffers under the loading overlay.
        await player.open(Media(ch.streamUrl), play: true);
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
  /// Pi backend has no audio-track API — retry is a plain reopen there.
  Future<void> _applyVideoOnly(TvChannel ch) async {
    if (_piMode) return;
    if (ch.id != _videoOnlyId) return;
    try {
      await _player?.setAudioTrack(AudioTrack.no());
    } catch (_) {}
  }

  /// Wait until [n] seconds are cached (or N+20s elapse on trickling
  /// sources — then play whatever we have rather than hanging forever).
  Future<void> _waitForPrebuffer(
      TvChannel ch, int n, int seq) async {
    final s = _state;
    final player = _player;
    if (s == null || player == null) return;
    final target = Duration(seconds: n);
    final done = Completer<void>();
    _prebufferDone = done;
    Timer? deadline;
    deadline = Timer(Duration(seconds: n + 20), () {
      if (!done.isCompleted) done.complete();
    });
    StreamSubscription<Duration>? sub;
    sub = player.stream.buffer.listen((buf) {
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
      await player.play();
    } catch (e) {
      s.setPlayError(e.toString());
    }
  }

  /// Every entry point funnels here. Marks loading instantly; the state
  /// listener opens the active backend (single path — no double-open,
  /// no orphan audio).
  /// A fresh normal play always restores audio (clears video-only mode).
  Future<void> playChannel(TvChannel ch) async {
    _videoOnlyId = null;
    _state?.play(ch);
  }

  /// Reopen the current channel with audio decoding disabled — escape hatch
  /// for sources whose audio track mpv genuinely cannot decode. The choice
  /// sticks to that channel until a fresh normal play from the TV grid.
  /// (Pi backend: plain reopen — playbin has no audio-track switch.)
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

  Future<void> toggle() async {
    try {
      if (_piMode) {
        final c = _piCtrl;
        if (c == null) return;
        try {
          if (!c.value.isInitialized) return;
        } catch (_) {
          return;
        }
        // Raw throughout: controller.play() would seekTo(0) on live streams.
        if (c.value.isPlaying) {
          await _piPauseRaw(c);
        } else {
          await _piPlayRaw(c);
          _lastFlowAt = DateTime.now();
        }
      } else {
        await _player?.playOrPause();
      }
    } catch (e) {
      debugPrint('toggle failed: $e');
    }
  }

  Future<void> _bumpVolume(int deltaMpv) async {
    try {
      if (_piMode) {
        final c = _piCtrl;
        final s = _state;
        if (c == null || s == null) return;
        final v =
            (s.volume + deltaMpv / 100.0).clamp(0.0, 1.0);
        await c.setVolume(v);
        s.setVolume(v);
        s.setMuted(v == 0);
      } else {
        final p = _player;
        if (p == null) return;
        await p.setVolume(
            (p.state.volume + deltaMpv).clamp(0, 100));
      }
    } catch (e) {
      debugPrint('volume bump failed: $e');
    }
  }

  Future<void> _toggleMute() async {
    try {
      if (_piMode) {
        final c = _piCtrl;
        final s = _state;
        if (c == null || s == null) return;
        if (s.muted || s.volume == 0) {
          await c.setVolume(0.8);
          s.setVolume(0.8);
          s.setMuted(false);
        } else {
          await c.setVolume(0);
          s.setMuted(true);
        }
      } else {
        final p = _player;
        if (p == null) return;
        final v = p.state.volume;
        await p.setVolume(v == 0 ? 80 : 0);
      }
    } catch (e) {
      debugPrint('mute failed: $e');
    }
  }

  Future<void> stop() async {
    _prebufferDone?.complete(); // release a waiting tank immediately
    _prebufferDone = null;
    _state?.stop(); // listener stops the backend; direct stop below is belt & braces
    try {
      if (_piMode) {
        await _teardownPi();
      } else {
        await _player?.stop();
      }
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _stallTimer?.cancel();
    _stallTimer = null;
    _loadWatchdog?.cancel();
    _loadWatchdog = null;
    _piPollTimer?.cancel();
    _piPollTimer = null;
    _prebufferDone?.complete();
    _prebufferDone = null;
    _state?.removeListener(_syncWithState);
    try {
      final old = _piCtrl;
      _piCtrl = null;
      if (old != null) {
        try {
          old.removeListener(_onPiUpdate);
        } catch (_) {}
        await old.dispose();
      }
    } catch (_) {}
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
    _videoCtrl = null;
    super.dispose();
  }
}
