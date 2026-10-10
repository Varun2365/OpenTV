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
import '../services/remote_command.dart';

class PlayerScreen extends StatefulWidget {
  final AppState state;
  final PlayerService player;
  const PlayerScreen(
      {super.key, required this.state, required this.player});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  Timer? _tick;
  StreamSubscription<RemoteKey>? _keySub;

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
    // Fresh tune-in flashes the info bar; AppState auto-hides it after 5s.
    widget.state.setInfoVisible(true);
    // Overlay OK (loading Cancel / error actions) arrives here — AppState
    // moves the focus index, this screen performs the focused action.
    _keySub =
        widget.state.keyStream.listen(_onOverlayKey);
  }

  void _onOverlayKey(RemoteKey k) {
    if (!mounted || k != RemoteKey.ok) return;
    final s = widget.state;
    if (s.playing == null || s.playerActionCount == 0) return;
    if (s.playError != null) {
      final i = s.playerBtnIndex;
      if (i == 0) {
        widget.player.retryCurrent();
      } else if (i == 1) {
        s.stop(); // Channels
      } else {
        widget.player.retryVideoOnly();
      }
    } else {
      s.stop(); // Cancel
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _keySub?.cancel();
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    // Any remote/TV keypress reshows the info bar (if settled) and
    // restarts its 5s auto-hide clock. pokeInfo is silent when the bar
    // is already up, so this can never notify in a loop.
    if (!_loading &&
        widget.state.lastKeyAt
                .difference(DateTime.now())
                .inSeconds
                .abs() <
            5) {
      widget.state.pokeInfo();
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
    final showChrome = s.infoVisible &&
        s.playError == null &&
        !_loading;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => widget.state.toggleInfo(),
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
                    child: Stack(
                      children: [
                        // Top-left: live status pill (spinner + elapsed).
                        Positioned(
                          top: 44,
                          left: 52,
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 12),
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
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    valueColor:
                                        AlwaysStoppedAnimation(
                                            Color(
                                                0xFFFFB338)),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                    slow
                                        ? 'CONNECTING • ${elapsed}s'
                                        : 'CONNECTING',
                                    style:
                                        const TextStyle(
                                            color: Color(
                                                0xFFF5F1E8),
                                            fontSize: 13,
                                            letterSpacing:
                                                2.5,
                                            fontWeight:
                                                FontWeight
                                                    .w700)),
                              ],
                            ),
                          ),
                        ),
                        // Center: roomy title block + wide tank progress.
                        Center(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(
                                    horizontal: 72),
                            child: Column(
                              mainAxisSize:
                                  MainAxisSize.min,
                              children: [
                                // Channel logo while loading (quiet box,
                                // never breaks layout if it 404s).
                                if ((ch?.logoUrl ?? '')
                                    .isNotEmpty) ...[
                                  Container(
                                    width: 104,
                                    height: 104,
                                    margin:
                                        const EdgeInsets.only(
                                            bottom: 24),
                                    decoration: BoxDecoration(
                                        color: const Color(
                                            0xFF1B1B24),
                                        borderRadius:
                                            BorderRadius.circular(
                                                26),
                                        border: Border.all(
                                            color:
                                                const Color(
                                                    0x33FFFFFF))),
                                    clipBehavior:
                                        Clip.antiAlias,
                                    child: Image.network(
                                      ch!.logoUrl,
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, err,
                                              stack) =>
                                          const Icon(
                                              Icons
                                                  .live_tv_rounded,
                                              color: Color(
                                                  0xFFFFB338),
                                              size: 48),
                                    ),
                                  ),
                                ],
                                Text(ch?.name ?? 'Channel',
                                    textAlign:
                                        TextAlign.center,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 54,
                                        height: 1.12,
                                        fontWeight:
                                            FontWeight
                                                .w800)),
                                const SizedBox(height: 20),
                                Text(
                                    elapsed >= 20
                                        ? 'This stream is struggling — cancel and try a green-dot channel…'
                                        : slow
                                            ? 'Still connecting — slow network or a dead link…'
                                            : (s.bufferingPct >
                                                    1
                                                ? 'Loading stream… ${s.bufferingPct.round()}%'
                                                : 'Opening stream…'),
                                    textAlign:
                                        TextAlign.center,
                                    style: const TextStyle(
                                        color: Color(
                                            0xFFB9B4C7),
                                        fontSize: 17)),
                                if (s.prebuffering &&
                                    s.prebufferTarget >
                                        0) ...[
                                  const SizedBox(
                                      height: 36),
                                  Text(
                                      'Filling tank… ${s.prebufferedSec.round()}s / ${s.prebufferTarget}s',
                                      textAlign:
                                          TextAlign.center,
                                      style: const TextStyle(
                                          color: Color(
                                              0xFFF2F0EA),
                                          fontSize: 17,
                                          fontWeight:
                                              FontWeight
                                                  .w700)),
                                  const SizedBox(
                                      height: 18),
                                  SizedBox(
                                    width: 480,
                                    child: ClipRRect(
                                      borderRadius:
                                          BorderRadius
                                              .circular(
                                                  999),
                                      child:
                                          LinearProgressIndicator(
                                        value: (s.prebufferedSec /
                                                s.prebufferTarget)
                                            .clamp(
                                                0.0, 1.0),
                                        minHeight: 8,
                                        backgroundColor:
                                            const Color(
                                                0x33FFFFFF),
                                        valueColor:
                                            const AlwaysStoppedAnimation(
                                                Color(
                                                    0xFFFFB338)),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        // Bottom-center: Cancel — reachable via D-pad /
                        // phone remote (AppState.playerBtnIndex).
                        Positioned(
                          bottom: 60,
                          left: 0,
                          right: 0,
                          child: Column(
                            mainAxisSize:
                                MainAxisSize.min,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () =>
                                    widget.state.stop(),
                                icon: const Icon(
                                    Icons.close_rounded,
                                    size: 22),
                                label:
                                    const Text('Cancel'),
                                style: _ovlOutlined(
                                    s.playerFocusVisible &&
                                        s.playerBtnIndex ==
                                            0),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                  '▼ FOCUS  •  OK CANCEL',
                                  style: TextStyle(
                                      color: Color(
                                          0xFF6E6A7E),
                                      fontSize: 12,
                                      letterSpacing: 2,
                                      fontWeight:
                                          FontWeight.w600)),
                            ],
                          ),
                        ),
                      ],
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
                          const EdgeInsets.all(48),
                      padding:
                          const EdgeInsets.fromLTRB(
                              44, 40, 44, 36),
                      constraints:
                          const BoxConstraints(
                              maxWidth: 580),
                      decoration: BoxDecoration(
                          color: const Color(
                              0xFF16161D),
                          borderRadius:
                              BorderRadius.circular(
                                  24),
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
                              size: 54),
                          const SizedBox(height: 18),
                          const Text(
                              "COULDN'T PLAY",
                              style: TextStyle(
                                  color: Color(
                                      0xFFFF7A7A),
                                  fontSize: 12,
                                  letterSpacing: 2.5,
                                  fontWeight:
                                      FontWeight
                                          .w700)),
                          const SizedBox(height: 10),
                          Text(ch?.name ?? 'Channel',
                              textAlign:
                                  TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 27,
                                  fontWeight:
                                      FontWeight
                                          .w800)),
                          const SizedBox(height: 12),
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
                                  fontSize: 14)),
                          const SizedBox(height: 8),
                          const Text(
                              'The link may be dead — retry or pick another channel.',
                              textAlign:
                                  TextAlign.center,
                              style: TextStyle(
                                  color: Color(
                                      0xFF9A94A6),
                                  fontSize: 14)),
                          const SizedBox(height: 28),
                          Wrap(
                            alignment:
                                WrapAlignment.center,
                            spacing: 14,
                            runSpacing: 14,
                            children: [
                              ElevatedButton.icon(
                                onPressed: () =>
                                    widget.player
                                        .retryCurrent(),
                                icon: const Icon(
                                    Icons
                                        .refresh_rounded,
                                    size: 20),
                                label: const Text(
                                    'Retry'),
                                style: _ovlElevated(
                                    s.playerFocusVisible &&
                                        s.playerBtnIndex ==
                                            0),
                              ),
                              OutlinedButton(
                                onPressed: () =>
                                    widget.state
                                        .stop(),
                                style: _ovlOutlined(
                                    s.playerFocusVisible &&
                                        s.playerBtnIndex ==
                                            1),
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
                                      size: 20),
                                  label: const Text(
                                      'Video only'),
                                  style: _ovlOutlined(
                                      s.playerFocusVisible &&
                                          s.playerBtnIndex ==
                                              2),
                                ),
                            ],
                          ),
                          const SizedBox(height: 22),
                          const Text(
                              '◀ ▶ CHOOSE  •  OK CONFIRM',
                              style: TextStyle(
                                  color: Color(
                                      0xFF6E6A7E),
                                  fontSize: 12,
                                  letterSpacing: 2,
                                  fontWeight:
                                      FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Bottom info bar (loaded only, fades; auto-hides after 5s).
            // Taller + darker scrim so text stays legible over bright video.
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
                            40, 84, 40, 46),
                    decoration:
                        const BoxDecoration(
                      gradient: LinearGradient(
                          begin:
                              Alignment.topCenter,
                          end: Alignment
                              .bottomCenter,
                          stops: [0.0, 0.45, 1.0],
                          colors: [
                            Colors.transparent,
                            Color(0xB3000000),
                            Color(0xE6000000)
                          ]),
                    ),
                    child: Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.center,
                      children: [
                        // Channel logo thumb (quiet box, never breaks
                        // layout if the logo 404s).
                        if ((ch?.logoUrl ?? '')
                            .isNotEmpty) ...[
                          Container(
                            width: 58,
                            height: 58,
                            margin:
                                const EdgeInsets.only(
                                    right: 16),
                            decoration: BoxDecoration(
                                color: const Color(
                                    0xFF1B1B24),
                                borderRadius:
                                    BorderRadius.circular(
                                        15),
                                border: Border.all(
                                    color:
                                        const Color(
                                            0x33FFFFFF))),
                            clipBehavior: Clip.antiAlias,
                            child: Image.network(
                              ch!.logoUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, err, stack) =>
                                  const Icon(
                                      Icons
                                          .live_tv_rounded,
                                      color: Color(
                                          0xFFFFB338),
                                      size: 28),
                            ),
                          ),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment
                                    .start,
                            mainAxisSize:
                                MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisSize:
                                    MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration:
                                        const BoxDecoration(
                                            color: Color(
                                                0xFF3DDC84),
                                            shape: BoxShape
                                                .circle,
                                            boxShadow: [
                                          BoxShadow(
                                              color: Color(
                                                  0xFF3DDC84),
                                              blurRadius:
                                                  8)
                                        ]),
                                  ),
                                  const SizedBox(
                                      width: 8),
                                  const Text('LIVE',
                                      style: TextStyle(
                                          color: Color(
                                              0xFF3DDC84),
                                          fontSize: 12,
                                          letterSpacing:
                                              2.5,
                                          fontWeight:
                                              FontWeight
                                                  .w800)),
                                  if ((ch?.category ??
                                          '')
                                      .isNotEmpty) ...[
                                    const SizedBox(
                                        width: 10),
                                    Flexible(
                                      child: Text(
                                          ch!.category
                                              .toUpperCase(),
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow
                                                  .ellipsis,
                                          style:
                                              const TextStyle(
                                                  color: Color(
                                                      0xFF9A94A6),
                                                  fontSize:
                                                      11,
                                                  letterSpacing:
                                                      1.6,
                                                  fontWeight:
                                                      FontWeight
                                                          .w700)),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(ch?.name ?? '',
                                  maxLines: 1,
                                  overflow:
                                      TextOverflow.ellipsis,
                                  style:
                                      const TextStyle(
                                          color: Colors
                                              .white,
                                          fontSize:
                                              30,
                                          height: 1.1,
                                          fontWeight:
                                              FontWeight
                                                  .w800)),
                              if (s.qualityLabel
                                  .isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(s.qualityLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow
                                        .ellipsis,
                                    style:
                                        const TextStyle(
                                            color: Color(
                                                0xFFB9B4C7),
                                            fontSize:
                                                13)),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
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

  static const _gold = Color(0xFFFFB338);

  /// Overlay buttons (loading Cancel / error actions): the TV D-pad and
  /// the phone remote move AppState.playerBtnIndex, and the focused
  /// button glows gold so the couch can see where focus is.
  ButtonStyle _ovlOutlined(bool focused) =>
      OutlinedButton.styleFrom(
          foregroundColor:
              focused ? _gold : Colors.white,
          backgroundColor: focused
              ? const Color(0x22FFB338)
              : Colors.transparent,
          side: BorderSide(
              color: focused
                  ? _gold
                  : const Color(0x44FFFFFF),
              width: focused ? 2 : 1),
          padding: const EdgeInsets.symmetric(
              horizontal: 38, vertical: 19),
          textStyle: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w700));

  ButtonStyle _ovlElevated(bool focused) =>
      ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFF2F0EA),
          foregroundColor: const Color(0xFF000000),
          side: BorderSide(
              color: focused
                  ? _gold
                  : Colors.transparent,
              width: 2),
          padding: const EdgeInsets.symmetric(
              horizontal: 38, vertical: 19),
          textStyle: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w800));

  String _shortError(String e) {
    // media_kit errors are verbose — keep the first meaningful line.
    var t = e.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length > 180) t = '${t.substring(0, 180)}…';
    return t;
  }
}
