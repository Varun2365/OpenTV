// 10-foot OTT home in the style of the Daily-UI-88 reference:
// floating near-black rounded panel, white pill nav, portrait poster rails.
// 60fps rules for Pi 4 + flutter-pi: no blur, transform/opacity-only motion,
// capped rails, RepaintBoundary per card, 360px image cache.
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/tv_channel.dart';
import '../services/app_state.dart';
import '../services/remote_command.dart';

const double _kCardExtent = 208; // 188 card + 12 gap + 8 glow margin
const Color _kPanel = Color(0xFF08080B);
const Color _kAccent = Color(0xFF3D9BFF); // home accent: glow + actions
const Color _kPill = Color(0xFF1D1D21);
const Color _kPaper = Color(0xFFF2F0EA);
const Color _kMuted = Color(0xFF8E8B96);
const Color _kLive = Color(0xFFFF6B6B);

class TvHome extends StatefulWidget {
  final AppState state;
  final Future<void> Function(TvChannel) onPlay;
  const TvHome({super.key, required this.state, required this.onPlay});

  @override
  State<TvHome> createState() => _TvHomeState();
}

class _TvHomeState extends State<TvHome> {
  final ScrollController _vertical = ScrollController();
  final Map<int, ScrollController> _railScroll = {};
  final Map<int, GlobalKey> _railKeys = {};
  final FocusNode _focusNode = FocusNode();
  bool _firstFrame = true;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _firstFrame = false;
      _scrollToFocused(animated: false);
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _vertical.dispose();
    for (final c in _railScroll.values) {
      c.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToFocused(animated: true);
    });
  }

  void _scrollToFocused({required bool animated}) {
    final s = widget.state;
    if (s.rails.isEmpty) return;
    final rail = s.railIndex.clamp(0, s.rails.length - 1);

    final key = _railKeys.putIfAbsent(rail, () => GlobalKey());
    final ctx = key.currentContext;
    if (ctx != null && _vertical.hasClients) {
      if (animated && !_firstFrame) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.28,
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic);
      } else {
        Scrollable.ensureVisible(ctx, alignment: 0.28);
      }
    }

    final ctrl =
        _railScroll.putIfAbsent(rail, () => ScrollController());
    if (ctrl.hasClients) {
      try {
        final viewW = MediaQuery.sizeOf(context).width;
        final max = ctrl.position.maxScrollExtent;
        final target = (s.cardIndex * _kCardExtent -
                viewW / 2 +
                _kCardExtent / 2)
            .clamp(0.0, max);
        if ((ctrl.offset - target).abs() > 8) {
          if (animated && !_firstFrame) {
            ctrl.animateTo(target,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic);
          } else {
            ctrl.jumpTo(target);
          }
        }
      } catch (_) {}
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final s = widget.state;
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      s.handleKey(RemoteKey.up);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      s.handleKey(RemoteKey.down);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      s.handleKey(RemoteKey.left);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      s.handleKey(RemoteKey.right);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.select ||
        e.logicalKey == LogicalKeyboardKey.space) {
      s.handleKey(RemoteKey.ok); // grid: play · nav: jump to rail
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape ||
        e.logicalKey == LogicalKeyboardKey.goBack) {
      s.handleKey(RemoteKey.back);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, e) => _onKey(node, e),
      child: Scaffold(
        // Full-bleed: no floating panel, no outer radius — the UI owns
        // 100% of the screen edge to edge.
        backgroundColor: _kPanel,
        body: SafeArea(
          child: s.catalogLoading
              ? _loading(s)
              : s.rails.isEmpty
                  ? _empty(s)
                  : Column(
                      children: [
                        _navBar(context, s),
                        Expanded(
                          child: CustomScrollView(
                            controller: _vertical,
                            physics:
                                const BouncingScrollPhysics(),
                            slivers: [
                              SliverToBoxAdapter(
                                  child: _spotlight(
                                      context, s)),
                              for (var i = 0;
                                  i < s.rails.length;
                                  i++)
                                SliverToBoxAdapter(
                                    child: _rail(
                                        context,
                                        s,
                                        i)),
                              SliverToBoxAdapter(
                                  child:
                                      _footer(s)),
                            ],
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }

  // ── Loading / empty ──────────────────────────────────────────────
  Widget _loading(AppState s) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: const BoxDecoration(
                  color: _kPaper, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Icon(Icons.live_tv_rounded,
                  color: Colors.black, size: 30),
            ),
            const SizedBox(height: 20),
            const Text('OpenTV',
                style: TextStyle(
                    color: _kPaper,
                    fontSize: 26,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                  strokeWidth: 3.5,
                  valueColor: AlwaysStoppedAnimation(
                      _kPaper)),
            ),
            const SizedBox(height: 12),
            Text(s.catalogStatus,
                style: const TextStyle(
                    color: _kMuted, fontSize: 14)),
          ],
        ),
      );

  Widget _empty(AppState s) => Center(
        child: Text('No channels found.\n${s.catalogStatus}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _kMuted)),
      );

  // ── Pill nav (sticky, like the reference) ─────────────────────────
  Widget _navBar(BuildContext context, AppState s) {
    final tabs = s.navTabs;
    final inNav = s.zone == FocusZone.nav;
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(28, 22, 28, 14),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
                color: _kPill, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const Icon(Icons.live_tv_rounded,
                color: _kPaper, size: 26),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Padding(
                      padding:
                          const EdgeInsets.only(right: 10),
                      child: _pill(
                          label: tabs[i].label,
                          icon: _tabIcon(tabs[i].label),
                          active: inNav
                              ? i == s.tabIndex
                              : i == s.activeTab,
                          dimmed: !inNav &&
                              i != s.activeTab,
                          onTap: () {
                            s.tabIndex = i;
                            s.activateTab();
                          }),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 18),
          const ClockPill(),
          const SizedBox(width: 10),
          _circleBtn(Icons.settings_outlined,
              () => _showSettings(context, s)),
        ],
      ),
    );
  }

  IconData _tabIcon(String label) {
    switch (label) {
      case 'Home':
        return Icons.home_rounded;
      case 'India':
        return Icons.flag_rounded;
      case 'Global':
        return Icons.public_rounded;
      case 'News':
        return Icons.newspaper_rounded;
      case 'Sports':
        return Icons.sports_cricket_rounded;
      case 'Music':
        return Icons.music_note_rounded;
      case 'Kids':
        return Icons.child_care_rounded;
      case 'Movies':
        return Icons.movie_rounded;
      case 'My Lists':
        return Icons.star_rounded;
      default:
        return Icons.folder_rounded;
    }
  }

  Widget _pill(
      {required String label,
      required IconData icon,
      required bool active,
      bool dimmed = false,
      VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration:
            const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(
            horizontal: 22, vertical: 14),
        decoration: BoxDecoration(
          color:
              active ? _kPaper : _kPill,
          borderRadius:
              BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 20,
                color: active
                    ? Colors.black
                    : dimmed
                        ? _kMuted
                        : _kPaper),
            const SizedBox(width: 9),
            Text(label,
                style: TextStyle(
                    color: active
                        ? Colors.black
                        : dimmed
                            ? _kMuted
                            : _kPaper,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          decoration: const BoxDecoration(
              color: _kPill,
              shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Icon(icon,
              color: _kPaper, size: 24),
        ),
      );

  void _showSettings(BuildContext context, AppState s) {
    final url =
        s.lanUrls.isNotEmpty ? s.lanUrls.first : '…';
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: const Color(0xFF141417),
        shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(26)),
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Phone remote',
                  style: TextStyle(
                      color: _kPaper,
                      fontSize: 20,
                      fontWeight:
                          FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                  'Open this on your phone (same Wi-Fi)',
                  style: const TextStyle(
                      color: _kMuted,
                      fontSize: 13.5)),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: _kPaper,
                    borderRadius:
                        BorderRadius.circular(20)),
                child: QrImageView(
                    data: url, size: 170),
              ),
              const SizedBox(height: 14),
              Text(url,
                  style: const TextStyle(
                      color: _kPaper,
                      fontSize: 14,
                      fontWeight:
                          FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                  '${s.allChannels.length} channels • ${s.customPlaylists.length} saved lists',
                  style: const TextStyle(
                      color: _kMuted,
                      fontSize: 12.5)),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () =>
                    Navigator.of(context).pop(),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(
                          horizontal: 34,
                          vertical: 14),
                  decoration: BoxDecoration(
                      color: _kPaper,
                      borderRadius:
                          BorderRadius.circular(
                              999)),
                  child: const Text('Done',
                      style: TextStyle(
                          color: Colors.black,
                          fontSize: 15,
                          fontWeight:
                              FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Spotlight: compact now-browsing strip ──────────────────────────
  Widget _spotlight(BuildContext context, AppState s) {
    final f = s.focusedChannel;
    final live = _isLive(f);
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(28, 6, 28, 20),
      child: Container(
        height: 118,
        padding: const EdgeInsets.symmetric(
            horizontal: 22, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF101014),
          borderRadius:
              BorderRadius.circular(26),
          border: Border.all(
              color: const Color(0x14FFFFFF)),
        ),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: const Duration(
                  milliseconds: 220),
              transitionBuilder:
                  (child, anim) => FadeTransition(
                      opacity: anim, child: child),
              child: Container(
                key: ValueKey('spot-${f?.id}'),
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                    color: const Color(0xFF1B1B1F),
                    borderRadius:
                        BorderRadius.circular(20)),
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                child: (f == null ||
                        f.logoUrl.isEmpty)
                    ? const Icon(
                        Icons.live_tv_rounded,
                        color: _kPaper,
                        size: 34)
                    : CachedNetworkImage(
                        imageUrl: f.logoUrl,
                        memCacheWidth: 240,
                        fit: BoxFit.contain,
                        fadeInDuration:
                            const Duration(
                                milliseconds:
                                    200),
                        errorWidget:
                            (context, url, error) =>
                                const Icon(
                                    Icons
                                        .live_tv_rounded,
                                    color: _kPaper,
                                    size: 34),
                      ),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(
                    milliseconds: 220),
                transitionBuilder:
                    (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                            position: Tween(
                                    begin:
                                        const Offset(
                                            0.04, 0),
                                    end: Offset.zero)
                                .animate(anim),
                            child: child)),
                layoutBuilder:
                    (current, previous) => Stack(
                        alignment:
                            Alignment.centerLeft,
                        children: [
                          ...previous,
                          ?current
                        ]),
                child: Column(
                  key: ValueKey(f?.id ?? 'none'),
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (live) ...[
                          const PulseDot(),
                          const SizedBox(width: 7),
                          const Text('LIVE',
                              style: TextStyle(
                                  color: _kLive,
                                  fontSize: 11,
                                  letterSpacing: 2,
                                  fontWeight:
                                      FontWeight
                                          .w800)),
                        ] else
                          const Text(
                              'NOW BROWSING',
                              style: TextStyle(
                                  color: _kAccent,
                                  fontSize: 11,
                                  letterSpacing: 2,
                                  fontWeight:
                                      FontWeight
                                          .w700)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(f?.name ?? 'OpenTV',
                        maxLines: 1,
                        overflow:
                            TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: _kPaper,
                            fontSize: 25,
                            fontWeight:
                                FontWeight.w800,
                            letterSpacing: -0.3)),
                    Text(f?.category ?? '',
                        maxLines: 1,
                        overflow:
                            TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: _kMuted,
                            fontSize: 13)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            GestureDetector(
              onTap: f == null
                  ? null
                  : () => widget.onPlay(f),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(
                        horizontal: 26,
                        vertical: 16),
                decoration: BoxDecoration(
                    color: _kAccent,
                    borderRadius:
                        BorderRadius.circular(
                            999)),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 22),
                    SizedBox(width: 6),
                    Text('Play',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight:
                                FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Poster rail ───────────────────────────────────────────────────
  Widget _rail(BuildContext context, AppState s, int i) {
    final rail = s.rails[i];
    final focused = s.zone == FocusZone.grid &&
        s.railIndex == i;
    final ctrl = _railScroll.putIfAbsent(
        i, () => ScrollController());
    return Padding(
      key: _railKeys.putIfAbsent(i, () => GlobalKey()),
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                30, 0, 30, 12),
            child: Row(
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(
                      milliseconds: 200),
                  style: TextStyle(
                      color: focused
                          ? _kPaper
                          : const Color(0xFFB9B5C2),
                      fontSize: 19,
                      fontWeight:
                          FontWeight.w600),
                  child: Text(rail.title),
                ),
                const SizedBox(width: 10),
                Text('${rail.channels.length}',
                    style: const TextStyle(
                        color: Color(0xFF55555F),
                        fontSize: 14)),
              ],
            ),
          ),
          SizedBox(
            // Tall enough that the focused card's scale + glow never
            // touch the viewport edge (no clipped borders), and unclipped
            // so the halo breathes instead of getting cut.
            height: 344,
            child: ListView.builder(
              controller: ctrl,
              clipBehavior: Clip.none,
              scrollDirection: Axis.horizontal,
              physics:
                  const BouncingScrollPhysics(),
              padding:
                  const EdgeInsets.symmetric(
                      horizontal: 30),
              itemExtent: _kCardExtent,
              itemCount: rail.channels.length,
              itemBuilder: (c, j) {
                final ch = rail.channels[j];
                final isFocus =
                    focused && s.cardIndex == j;
                return RepaintBoundary(
                    child: _posterCard(
                        ch,
                        isFocus,
                        s.healthById[ch.id] ??
                            'unknown',
                        () =>
                            widget.onPlay(ch)));
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _posterCard(TvChannel ch, bool isFocus, String health,
          VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(right: 12),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedScale(
            scale: isFocus ? 1.05 : 1.0,
            duration: const Duration(
                milliseconds: 180),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(
                  milliseconds: 180),
              curve: Curves.easeOut,
              width: 188,
              decoration: BoxDecoration(
                color: const Color(0xFF17171B),
                borderRadius:
                    BorderRadius.circular(4),
                // Focus = whisper-thin light-blue border + big blue halo
                // (never a chunky ring).
                border: Border.all(
                    color: isFocus
                        ? const Color(0xCC3D9BFF)
                        : Colors.transparent,
                    width: 1.5),
                boxShadow: isFocus
                    ? const [
                        BoxShadow(
                            color: Color(
                                0x883D9BFF),
                            blurRadius: 36,
                            spreadRadius: 3,
                            offset: Offset(0, 8)),
                      ]
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    alignment: Alignment.center,
                    padding:
                        const EdgeInsets.all(26),                    child: ch.logoUrl.isEmpty
                        ? const Icon(
                            Icons
                                .live_tv_rounded,
                            color: _kPaper,
                            size: 44)
                        : CachedNetworkImage(
                            imageUrl: ch.logoUrl,
                            memCacheWidth: 360,
                            fit: BoxFit.contain,
                            fadeInDuration:
                                const Duration(
                                    milliseconds:
                                        200),
                            errorWidget: (context,
                                    url, error) =>
                                const Icon(
                                    Icons
                                        .live_tv_rounded,
                                    color: _kPaper,
                                    size: 44),
                          ),
                  ),
                  if (health == 'slow' || health == 'dead')
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                              color: health == 'dead'
                                  ? _kLive
                                  : const Color(
                                      0xFFFFB338),
                              shape:
                                  BoxShape.circle)),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding:
                          const EdgeInsets.fromLTRB(
                              14, 26, 14, 13),
                      decoration:
                          const BoxDecoration(
                        gradient: LinearGradient(
                            begin: Alignment
                                .topCenter,
                            end: Alignment
                                .bottomCenter,
                            colors: [
                              Colors.transparent,
                              Color(0xE6000000)
                            ]),
                      ),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          if (_isLive(ch))
                            const Row(
                              mainAxisSize:
                                  MainAxisSize.min,
                              children: [
                                PulseDot(
                                    small: true),
                                SizedBox(width: 6),
                                Text('LIVE',
                                    style: TextStyle(
                                        color:
                                            _kLive,
                                        fontSize:
                                            10,
                                        letterSpacing:
                                            1.6,
                                        fontWeight:
                                            FontWeight
                                                .w800)),
                              ],
                            ),
                          Text(ch.name,
                              maxLines: 1,
                              overflow: TextOverflow
                                  .ellipsis,
                              style:
                                  const TextStyle(
                                      color: _kPaper,
                                      fontSize: 14.5,
                                      fontWeight:
                                          FontWeight
                                              .w700)),
                          Text(ch.category,
                              maxLines: 1,
                              overflow: TextOverflow
                                  .ellipsis,
                              style:
                                  const TextStyle(
                                      color: Color(
                                          0xFFA7A3B3),
                                      fontSize:
                                          11.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _footer(AppState s) => Padding(
        padding:
            const EdgeInsets.fromLTRB(30, 2, 30, 30),
        child: Text(
            '↑↓ rails • ←→ channels • OK play • CH +/− zap • ${s.allChannels.length} free channels',
            style: const TextStyle(
                color: Color(0xFF55555F),
                fontSize: 12.5)),
      );

  bool _isLive(TvChannel? ch) {
    if (ch == null) return false;
    final t =
        '${ch.category} ${ch.name}'.toLowerCase();
    return t.contains('news') ||
        t.contains('live') ||
        t.contains('sports');
  }
}

/// Live clock pill for the nav bar (ticks every 30s — cheap).
class ClockPill extends StatefulWidget {
  const ClockPill({super.key});
  @override
  State<ClockPill> createState() =>
      _ClockPillState();
}

class _ClockPillState extends State<ClockPill> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(
        const Duration(seconds: 30),
        (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hh = now.hour
        .toString()
        .padLeft(2, '0');
    final mm = now.minute
        .toString()
        .padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
          color: _kPill,
          borderRadius:
              BorderRadius.circular(999)),
      child: Text('$hh:$mm',
          style: const TextStyle(
              color: _kPaper,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              fontFeatures: [
                FontFeature.tabularFigures()
              ])),
    );
  }
}

/// Small pulsing live dot — transform-only, cheap on Pi.
class PulseDot extends StatefulWidget {
  final bool small;
  const PulseDot({super.key, this.small = false});
  @override
  State<PulseDot> createState() =>
      _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(
          vsync: this,
          duration: const Duration(
              milliseconds: 1100))
        ..repeat(reverse: true);
  late final Animation<double> _s =
      Tween(begin: 1.0, end: 1.35).animate(
          CurvedAnimation(
              parent: _c,
              curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ScaleTransition(
        scale: _s,
        child: Container(
            width: widget.small ? 7 : 10,
            height: widget.small ? 7 : 10,
            decoration: const BoxDecoration(
                color: _kLive,
                shape: BoxShape.circle)),
      );
}
