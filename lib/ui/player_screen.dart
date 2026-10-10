// Fullscreen player: mpv surface + load / error / chrome states.
// States:
//  - loading: spinner + channel + slow-network hint + Cancel (no blind black).
//  - error: card with message + Retry + Back.
//  - rebuffer: small top pill while video keeps last frame.
//  - loaded: minimal bottom chrome, auto-hides. No blur anywhere (Pi 60fps).
// All overlays fade via AnimatedOpacity (opacity-only = cheap on Pi).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/tv_channel.dart';
import '../services/app_state.dart';
import '../services/player_service.dart';

class PlayerScreen extends StatefulWidget {
  final AppState state;
  final PlayerService player;
  const PlayerScreen(
      {super.key, required this.state, required this.player});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _chrome = true;
  Timer? _tick;

  bool get _loading {
    final s = widget.state;
    return s.playError == null &&
        (s.isBuffering || !s.hasVideo || s.prebuffering);
  }

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    // Rebuild once a second so "still connecting…" appears after 6s.
    _tick = Timer.periodic(
        const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && !_loading) {
        setState(() => _chrome = false);
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    if (widget.state.lastKeyAt
            .difference(DateTime.now())
            .inSeconds
            .abs() <
        5) {
      setState(() => _chrome = true);
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted && !_loading) {
          setState(() => _chrome = false);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final TvChannel? ch = s.playing;
    final elapsed =
        DateTime.now().difference(s.playRequestedAt).inSeconds;
    final slow = elapsed >= 6;
    final showPill = s.playError == null &&
        s.hasVideo &&
        s.isBuffering;
    final showChrome = _chrome &&
        s.playError == null &&
        !_loading;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _chrome = !_chrome),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Video(
                controller: widget.player.videoController,
                controls: NoVideoControls),
            // Rebuffer pill (video visible underneath).
            Positioned(
              top: 26,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedOpacity(
                  opacity: showPill ? 1 : 0,
                  duration: const Duration(
                      milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !showPill,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 9),
                      decoration: BoxDecoration(
                          color: const Color(
                              0xCC0B0B0F),
                          borderRadius:
                              BorderRadius.circular(
                                  999),
                          border: Border.all(
                              color: const Color(
                                  0x33FFFFFF))),
                      child: Row(
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor:
                                  AlwaysStoppedAnimation(
                                      Color(
                                          0xFFF2F0EA)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                              s.bufferingPct > 1
                                  ? 'Buffering… ${s.bufferingPct.round()}%'
                                  : 'Buffering…',
                              style:
                                  const TextStyle(
                                      color: Color(
                                          0xFFF5F1E8),
                                      fontSize: 13,
                                      fontWeight:
                                          FontWeight
                                              .w600)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Full loading overlay (fades in/out).
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: _loading ? 1 : 0,
                duration: const Duration(
                    milliseconds: 250),
                child: IgnorePointer(
                  ignoring: !_loading,
                  child: Container(
                    // Translucent veil (not solid black): the last video
                    // frame stays faintly visible underneath while loading.
                    color: const Color(0xB3000000),
                    alignment: Alignment.center,
                    child: Padding(
                      padding:
                          const EdgeInsets.all(36),
                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 52,
                            height: 52,
                            child:
                                CircularProgressIndicator(
                              strokeWidth: 4,
                              valueColor:
                                  AlwaysStoppedAnimation(
                                      Color(
                                          0xFFF2F0EA)),
                            ),
                          ),
                          const SizedBox(height: 22),
                          const Text('CONNECTING',
                              style: TextStyle(
                                  color: Color(
                                      0xFFF2F0EA),
                                  fontSize: 11,
                                  letterSpacing: 2.5,
                                  fontWeight:
                                      FontWeight
                                          .w700)),
                          const SizedBox(height: 8),
                          Text(ch?.name ?? 'Channel',
                              textAlign:
                                  TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight:
                                      FontWeight
                                          .w800)),
                          const SizedBox(height: 6),
                          Text(
                              elapsed >= 20
                                  ? 'This stream is struggling — hit Cancel and try a green-dot channel…'
                                  : slow
                                      ? 'Still connecting (${elapsed}s) — slow network or a dead link…'
                                      : (s.bufferingPct >
                                              1
                                          ? 'Loading stream… ${s.bufferingPct.round()}%'
                                          : 'Opening stream…'),
                              textAlign:
                                  TextAlign.center,
                              style: const TextStyle(
                                  color: Color(
                                      0xFFB9B4C7),
                                  fontSize: 13.5)),
                          const SizedBox(height: 22),
                          if (s.prebuffering &&
                              s.prebufferTarget > 0) ...[
                            Text(
                                'Filling tank… ${s.prebufferedSec.round()}s / ${s.prebufferTarget}s',
                                textAlign:
                                    TextAlign.center,
                                style: const TextStyle(
                                    color: Color(
                                        0xFFF2F0EA),
                                    fontSize: 14,
                                    fontWeight:
                                        FontWeight
                                            .w700)),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: 230,
                              child: ClipRRect(
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                            999),
                                child:
                                    LinearProgressIndicator(
                                  value: (s.prebufferedSec /
                                          s.prebufferTarget)
                                      .clamp(0.0, 1.0),
                                  minHeight: 6,
                                  backgroundColor:
                                      const Color(
                                          0x33FFFFFF),
                                  valueColor:
                                      const AlwaysStoppedAnimation(
                                          Color(
                                              0xFFF2F0EA)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          OutlinedButton.icon(
                            onPressed: () =>
                                widget.state.stop(),
                            icon: const Icon(
                                Icons.close_rounded,
                                size: 18),
                            label: const Text(
                                'Cancel'),
                            style: OutlinedButton
                                .styleFrom(
                                    foregroundColor:
                                        Colors.white,
                                    side: const BorderSide(
                                        color: Color(
                                            0x44FFFFFF)),
                                    padding: const EdgeInsets
                                        .symmetric(
                                        horizontal:
                                            26,
                                        vertical:
                                            14)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Error card (fades in/out).
            Positioned.fill(
              child: AnimatedOpacity(
                opacity:
                    s.playError != null ? 1 : 0,
                duration: const Duration(
                    milliseconds: 250),
                child: IgnorePointer(
                  ignoring: s.playError == null,
                  child: Container(
                    color: Colors.black,
                    alignment: Alignment.center,
                    child: Container(
                      margin:
                          const EdgeInsets.all(32),
                      padding:
                          const EdgeInsets.all(28),
                      constraints:
                          const BoxConstraints(
                              maxWidth: 520),
                      decoration: BoxDecoration(
                          color: const Color(
                              0xFF16161D),
                          borderRadius:
                              BorderRadius.circular(
                                  20),
                          border: Border.all(
                              color: const Color(
                                  0x22FFFFFF))),
                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          const Icon(
                              Icons
                                  .error_outline_rounded,
                              color:
                                  Color(0xFFFF7A7A),
                              size: 44),
                          const SizedBox(height: 14),
                          const Text(
                              "COULDN'T PLAY",
                              style: TextStyle(
                                  color: Color(
                                      0xFFFF7A7A),
                                  fontSize: 11,
                                  letterSpacing: 2,
                                  fontWeight:
                                      FontWeight
                                          .w700)),
                          const SizedBox(height: 6),
                          Text(ch?.name ?? 'Channel',
                              textAlign:
                                  TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight:
                                      FontWeight
                                          .w800)),
                          const SizedBox(height: 8),
                          Text(_shortError(
                                  s.playError ??
                                      ''),
                              textAlign:
                                  TextAlign.center,
                              maxLines: 3,
                              overflow: TextOverflow
                                  .ellipsis,
                              style: const TextStyle(
                                  color: Color(
                                      0xFF9A94A6),
                                  fontSize: 12.5)),
                          const SizedBox(height: 6),
                          const Text(
                              'The link may be dead — retry or pick another channel.',
                              textAlign:
                                  TextAlign.center,
                              style: TextStyle(
                                  color: Color(
                                      0xFF9A94A6),
                                  fontSize: 12.5)),
                          const SizedBox(height: 20),
                          Wrap(
                            alignment:
                                WrapAlignment.center,
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              ElevatedButton.icon(
                                onPressed: () =>
                                    widget.player
                                        .retryCurrent(),
                                icon: const Icon(
                                    Icons
                                        .refresh_rounded,
                                    size: 18),
                                label: const Text(
                                    'Retry',
                                    style: TextStyle(
                                        fontWeight:
                                            FontWeight
                                                .w800)),
                                style: ElevatedButton
                                    .styleFrom(
                                        backgroundColor:
                                            const Color(
                                                0xFFF2F0EA),
                                        foregroundColor:
                                            const Color(
                                                0xFF000000),
                                        padding: const EdgeInsets
                                            .symmetric(
                                            horizontal:
                                                26,
                                            vertical:
                                                14)),
                              ),
                              OutlinedButton(
                                onPressed: () =>
                                    widget.state
                                        .stop(),
                                style: OutlinedButton
                                    .styleFrom(
                                        foregroundColor:
                                            Colors
                                                .white,
                                        side: const BorderSide(
                                            color:
                                                Color(0x44FFFFFF)),
                                        padding: const EdgeInsets
                                            .symmetric(
                                            horizontal:
                                                26,
                                            vertical:
                                                14)),
                                child: const Text(
                                    'Channels'),
                              ),
                              // Escape hatch: the video is fine, only the
                              // audio track is undecodable — watch silent.
                              if ((s.playError ?? '')
                                  .toLowerCase()
                                  .contains('audio'))
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      widget.player
                                          .retryVideoOnly(),
                                  icon: const Icon(
                                      Icons
                                          .videocam_rounded,
                                      size: 18),
                                  label: const Text(
                                      'Video only'),
                                  style: OutlinedButton
                                      .styleFrom(
                                          foregroundColor:
                                              Colors
                                                  .white,
                                          side: const BorderSide(
                                              color:
                                                  Color(0x44FFFFFF)),
                                          padding: const EdgeInsets
                                              .symmetric(
                                              horizontal:
                                                  22,
                                              vertical:
                                                  14)),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Bottom chrome (loaded only, fades).
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: showChrome ? 1 : 0,
                duration: const Duration(
                    milliseconds: 250),
                child: IgnorePointer(
                  ignoring: !showChrome,
                  child: Container(
                    padding:
                        const EdgeInsets.fromLTRB(
                            36, 40, 36, 30),
                    decoration:
                        const BoxDecoration(
                      gradient: LinearGradient(
                          begin:
                              Alignment.topCenter,
                          end: Alignment
                              .bottomCenter,
                          colors: [
                            Colors.transparent,
                            Color(0xCC000000)
                          ]),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment
                                    .start,
                            mainAxisSize:
                                MainAxisSize.min,
                            children: [
                              const Text(
                                  'NOW PLAYING',
                                  style: TextStyle(
                                      color: Color(
                                          0xFFF2F0EA),
                                      fontSize: 11,
                                      letterSpacing: 2,
                                      fontWeight:
                                          FontWeight
                                              .w700)),
                              Text(ch?.name ?? '',
                                  style:
                                      const TextStyle(
                                          color: Colors
                                              .white,
                                          fontSize:
                                              26,
                                          fontWeight:
                                              FontWeight
                                                  .w800)),
                              Text(
                                  '${ch?.category ?? ''}${s.qualityLabel.isNotEmpty ? ' • ${s.qualityLabel}' : ''}  •  Back = home  •  Phone = remote',
                                  style:
                                      const TextStyle(
                                          color: Color(
                                              0xFFB9B4C7),
                                          fontSize:
                                              12.5)),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () =>
                              widget.player
                                  .toggle(),
                          icon: Icon(
                              s.isPlaying
                                  ? Icons.pause_circle
                                  : Icons.play_circle,
                              color: const Color(
                                  0xFFF2F0EA),
                              size: 52),
                        ),
                        IconButton(
                          onPressed: () =>
                              widget.state.stop(),
                          icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white,
                              size: 30),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _shortError(String e) {
    // media_kit errors are verbose — keep the first meaningful line.
    var t = e.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length > 180) t = '${t.substring(0, 180)}…';
    return t;
  }
}
