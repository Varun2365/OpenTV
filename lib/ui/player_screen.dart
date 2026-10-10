// Fullscreen player: mpv surface + load / error / chrome states.
// States:
//  - loading: spinner + channel + slow-network hint + Cancel (no blind black).
//  - error: card with message + Retry + Back.
//  - rebuffer: small top pill while video keeps last frame.
//  - loaded: minimal bottom chrome, auto-hides. No blur anywhere (Pi 60fps).
// All overlays fade via AnimatedOpacity (opacity-only = cheap on Pi).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:heroicons/heroicons.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

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
  // Player-list sidebar: fixed row height so selection scroll is exact.
  final ScrollController _plistCtrl = ScrollController();
  static const double _plistRowH = 68;
  int _lastPlistSel = -1;
  bool _lastPlistOpen = false;

  bool get _loading {
    final s = widget.state;
    return s.playError == null &&
        (s.isBuffering || !s.hasVideo || s.prebuffering);
  }

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    // Pi backend swaps its VideoPlayerController per channel — rebuild the
    // video surface when PlayerService notifies (desktop mpv controller is
    // stable, so this is a no-op there).
    widget.player.addListener(_onPlayerBackend);
    // Rebuild once a second so "still connecting…" appears after 6s.
    _tick = Timer.periodic(
        const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    // Fresh tune-in flashes the info bar; AppState auto-hides it after 5s.
    // Deferred past mount: initState runs inside AnimatedSwitcher's
    // SlideTransition build, so a synchronous notifyListeners() would
    // mark the parent ListenableBuilder dirty during build (crash).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.state.setInfoVisible(true);
    });
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
    _plistCtrl.dispose();
    widget.state.removeListener(_onState);
    widget.player.removeListener(_onPlayerBackend);
    super.dispose();
  }

  void _onPlayerBackend() {
    if (!mounted) return;
    setState(() {});
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    // Any remote/TV keypress reshows the info bar (if settled) and
    // restarts its 5s auto-hide clock. pokeInfo is silent when the bar
    // is already up, so this can never notify in a loop.
    // Deferred: _onState runs inside AppState.notifyListeners dispatch,
    // so a synchronous pokeInfo()->notify would re-enter dispatch and
    // can mark the ListenableBuilder dirty during build (same crash).
    if (!_loading &&
        widget.state.lastKeyAt
                .difference(DateTime.now())
                .inSeconds
                .abs() <
            5) {
      final s = widget.state;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        s.pokeInfo();
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
    final showChrome = s.infoVisible &&
        s.playError == null &&
        !_loading;

    // Player-list sidebar scroll: land on the playing channel when it
    // opens, then follow up/down selection. Deferred past build so the
    // controller jump never marks a widget dirty mid-build.
    final plistOpen = s.playerListOpen && ch != null;
    if (plistOpen) {
      final list = s.playerListChannels;
      final sel =
          list.isEmpty ? 0 : s.playerListIndex.clamp(0, list.length - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_plistCtrl.hasClients || list.isEmpty) return;
        if (_lastPlistOpen && _lastPlistSel == sel) return;
        _lastPlistOpen = true;
        _lastPlistSel = sel;
        final max = _plistCtrl.position.maxScrollExtent;
        final target =
            (sel * _plistRowH - 240).clamp(0.0, max);
        if ((target - _plistCtrl.offset).abs() < 1) return;
        try {
          _plistCtrl.animateTo(target,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic);
        } catch (_) {}
      });
    } else {
      _lastPlistOpen = false;
      _lastPlistSel = -1;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // Scrim tap while the list is open closes it (rows play on tap).
        onTap: () {
          final st = widget.state;
          if (st.playerListOpen) {
            st.closePlayerList();
          } else {
            st.toggleInfo();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _videoSurface(s),
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
            // Big mute badge, top-right — global until unmuted.
            Positioned(
              top: 26,
              right: 28,
              child: AnimatedOpacity(
                opacity:
                    (s.muted && s.playing != null)
                        ? 1
                        : 0,
                duration: const Duration(
                    milliseconds: 200),
                child: IgnorePointer(
                  ignoring:
                      !(s.muted && s.playing != null),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14),
                    decoration: BoxDecoration(
                        color: const Color(
                            0xCC0B0B0F),
                        borderRadius:
                            BorderRadius.circular(
                                18),
                        border: Border.all(
                            color: const Color(
                                0x66FF7A7A))),
                    child: const Column(
                      mainAxisSize:
                          MainAxisSize.min,
                      children: [
                        Icon(
                            Icons
                                .volume_off_rounded,
                            color: Color(
                                0xFFFF7A7A),
                            size: 46),
                        SizedBox(height: 6),
                        Text('MUTED',
                            style: TextStyle(
                                color: Color(
                                    0xFFFF7A7A),
                                fontSize: 11,
                                letterSpacing: 2.5,
                                fontWeight:
                                    FontWeight
                                        .w800)),
                      ],
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
                                          const HeroIcon(
                                              HeroIcons.tv,
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
                                icon: const HeroIcon(
                                    HeroIcons.xMark,
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
                          const HeroIcon(
                              HeroIcons.exclamationTriangle,
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
                                icon: const HeroIcon(
                                    HeroIcons.arrowPath,
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
                                  icon: const HeroIcon(
                                      HeroIcons.videoCamera,
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
                                  const HeroIcon(
                                      HeroIcons.tv,
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
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Player-list sidebar (phone "Channels" button): dim scrim +
            // kinda-transparent right list. Rows play on tap; ▲▼ + OK on
            // the TV / phone D-pad walk the list via AppState.
            if (plistOpen) _playerListOverlay(s),
          ],
        ),
      ),
    );
  }

  /// Video surface per backend. Desktop renders mpv via media_kit's Texture;
  /// flutter-pi has no media_kit native side (linux/runner is never built
  /// there), so the Pi renders gstreamer via video_player's Texture that
  /// flutter-pi DOES implement. Same fit semantics on both (remote
  /// "stretch" toggle: fill vs contain).
  Widget _videoSurface(AppState s) {
    final p = widget.player;
    if (p.isPiMode) {
      final c = p.piController;
      if (c != null) {
        try {
          if (c.value.isInitialized) {
            final w = c.value.size.width;
            final h = c.value.size.height;
            return SizedBox.expand(
              child: FittedBox(
                fit: s.stretchVideo ? BoxFit.fill : BoxFit.contain,
                child: SizedBox(
                  width: w > 0 ? w : 1280,
                  height: h > 0 ? h : 720,
                  child: VideoPlayer(c),
                ),
              ),
            );
          }
        } catch (_) {}
      }
      return Container(color: Colors.black);
    }
    final mpv = p.videoController;
    if (mpv == null) return Container(color: Colors.black);
    return Video(
        controller: mpv,
        // Remote "stretch" toggle: fill the screen or keep the
        // original shape. Rebuilds live via the state listener.
        fit: s.stretchVideo ? BoxFit.fill : BoxFit.contain,
        controls: NoVideoControls);
  }

  /// Right-side channel list for the current rail. Semi-transparent so
  /// the video stays faintly visible; the selection row glows gold.
  Widget _playerListOverlay(AppState s) {
    final list = s.playerListChannels;
    final sel =
        list.isEmpty ? 0 : s.playerListIndex.clamp(0, list.length - 1);
    final playingId = s.playing?.id;
    return Positioned.fill(
      child: Row(
        children: [
          // Dim the video on the left; the outer GestureDetector tap
          // closes the list.
          Expanded(
            child: Container(color: const Color(0x88000000)),
          ),
          Container(
            width: 400,
            color: const Color(0xD2101016),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 26, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(s.playerListTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text('${list.length} channels • this list',
                                style: const TextStyle(
                                    color: Color(0xFF9A94A6),
                                    fontSize: 12)),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => s.closePlayerList(),
                        icon: const Icon(Icons.close_rounded,
                            color: Color(0xFFF5F1E8)),
                        tooltip: 'Close',
                      ),
                    ],
                  ),
                ),
                const Divider(
                    height: 1, color: Color(0x22FFFFFF)),
                Expanded(
                  child: list.isEmpty
                      ? const Center(
                          child: Text('Nothing in this list.',
                              style: TextStyle(
                                  color: Color(0xFF9A94A6),
                                  fontSize: 14)),
                        )
                      : ListView.builder(
                          controller: _plistCtrl,
                          itemExtent: _plistRowH,
                          itemCount: list.length,
                          itemBuilder: (context, i) {
                            final c = list[i];
                            final isSel = i == sel;
                            final isPlaying =
                                c.id == playingId;
                            return _plistRow(s, c, i,
                                isSel: isSel,
                                isPlaying: isPlaying);
                          },
                        ),
                ),
                const Divider(
                    height: 1, color: Color(0x22FFFFFF)),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('▲ ▼ MOVE  •  OK PLAY',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Color(0xFF6E6A7E),
                          fontSize: 12,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _plistRow(AppState s, TvChannel c, int index,
      {required bool isSel, required bool isPlaying}) {
    final health = s.healthById[c.id];
    final dot = health == 'fast'
        ? const Color(0xFF3DDC84)
        : health == 'slow'
            ? const Color(0xFFFFB338)
            : health == 'dead'
                ? const Color(0xFFFF5A5A)
                : const Color(0xFF4A4A54);
    return Material(
      color: isSel
          ? const Color(0x22FFB338)
          : Colors.transparent,
      child: InkWell(
        onTap: () => s.tapPlayerList(index),
        child: Container(
          height: _plistRowH,
          padding:
              const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                  color: isSel
                      ? _gold
                      : Colors.transparent,
                  width: 3),
              bottom: const BorderSide(
                  color: Color(0x14FFFFFF)),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 12),
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                    color: const Color(0xFF1B1B24),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                        color: const Color(0x33FFFFFF))),
                clipBehavior: Clip.antiAlias,
                child: c.logoUrl.isNotEmpty
                    ? Image.network(c.logoUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, err, stack) =>
                            const HeroIcon(HeroIcons.tv,
                                color: Color(0xFFFFB338),
                                size: 22))
                    : const HeroIcon(HeroIcons.tv,
                        color: Color(0xFFFFB338), size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: isSel
                                ? _gold
                                : Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                        isPlaying
                            ? '● PLAYING'
                            : c.category.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: isPlaying
                                ? const Color(0xFF3DDC84)
                                : const Color(0xFF9A94A6),
                            fontSize: 11,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
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
