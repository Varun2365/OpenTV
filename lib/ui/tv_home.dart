// 10-foot StreamFlix-style home: left category sidebar, right channel
// grid for the selected category only. D-pad flows sidebar <-> grid.
// 60fps rules for Pi 4 + flutter-pi: no blur, transform/opacity-only motion,
// builder grids (9000 channels cost ~visible tiles), 360px image cache.
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:heroicons/heroicons.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/tv_channel.dart';
import '../services/app_state.dart';
import '../services/remote_command.dart';

const Color _kPanel = Color(0xFF08080B);
const Color _kSide = Color(0xFF0D0D11);
const Color _kAccent = Color(0xFF3D9BFF); // home accent: glow + actions
const Color _kPaper = Color(0xFFF2F0EA);
const Color _kMuted = Color(0xFF8E8B96);
const Color _kLive = Color(0xFFFF6B6B);
const double _kSideW = 236;

class TvHome extends StatefulWidget {
  final AppState state;
  final Future<void> Function(TvChannel) onPlay;
  const TvHome({super.key, required this.state, required this.onPlay});

  @override
  State<TvHome> createState() => _TvHomeState();
}

class _TvHomeState extends State<TvHome> {
  final ScrollController _gridCtrl = ScrollController();
  final Map<int, GlobalKey> _tileKeys = {};
  final FocusNode _focusNode = FocusNode();
  bool _firstFrame = true;
  int _lastSide = 0;

  // Long-press OK on the TV toggles favourite (short press plays).
  DateTime? _okDownAt;
  Timer? _okTimer;
  bool _okLongFired = false;

  String? _toast;
  Timer? _toastTimer;

  // QR auto-show: pops the remote dialog while no web remote is linked.
  bool _qrOpen = false;
  bool _qrAutoClosed = false;
  bool _qrSuppressed = false;
  Timer? _qrGrace;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    // Sync the category tracker at mount: otherwise the first state
    // notification after returning from the player looks like a fresh
    // category switch and _onState jumps the grid to the top,
    // orphaning the (preserved) deep focus below the fold.
    _lastSide = widget.state.sideIndex;
    // Persist the exact grid pixels continuously: this widget is
    // unmounted while the player is up, so Back lands on the same
    // scroll amount, selection and sidebar as at play time.
    _gridCtrl.addListener(_saveHomeScroll);
    // Precache the photo backdrop so it never pops in late.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        precacheImage(
            const AssetImage('assets/images/bg.png'), context);
      } catch (_) {}
      _focusNode.requestFocus();
      _firstFrame = false;
      final saved = widget.state.homeScrollOffset;
      if (saved > 0 && _gridCtrl.hasClients) {
        try {
          final max = _gridCtrl.position.maxScrollExtent;
          _gridCtrl.jumpTo(saved.clamp(0, max));
        } catch (_) {}
      } else {
        _scrollToFocused(animated: false);
      }
    });
  }

  void _saveHomeScroll() {
    if (_gridCtrl.hasClients) {
      widget.state.homeScrollOffset = _gridCtrl.offset;
    }
  }

  @override
  void dispose() {
    _saveHomeScroll();
    _gridCtrl.removeListener(_saveHomeScroll);
    widget.state.removeListener(_onState);
    _gridCtrl.dispose();
    _focusNode.dispose();
    _okTimer?.cancel();
    _toastTimer?.cancel();
    _qrGrace?.cancel();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    final s = widget.state;
    // Self-healing keyboard focus: dialogs and the player screen steal it
    // (critical for PC testing). Never yank it back while another route
    // — e.g. the QR dialog — is on top.
    final routeCurrent =
        ModalRoute.of(context)?.isCurrent ?? true;
    if (routeCurrent && !_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
    if (s.sideIndex != _lastSide) {
      _lastSide = s.sideIndex;
      _tileKeys.clear();
      // Fresh category starts at the top.
      if (_gridCtrl.hasClients) _gridCtrl.jumpTo(0);
    }
    _autoQr(s);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToFocused(animated: true);
    });
  }

  /// QR auto-show: while no web remote is linked (and the user allowed
  /// it), pop the dialog after a grace delay. A fresh link dismisses it
  /// instantly; a manual close stays shut until the next link. Never fires
  /// over the player — this widget only exists on home.
  void _autoQr(AppState s) {
    if (s.remoteConnected) {
      _qrSuppressed = false; // next outage may pop again
      _qrGrace?.cancel();
      if (_qrOpen) {
        _qrOpen = false;
        _qrAutoClosed = true;
        try {
          Navigator.of(context, rootNavigator: true)
              .maybePop();
        } catch (_) {}
      }
      return;
    }
    if (!s.autoQr ||
        _qrSuppressed ||
        _qrOpen ||
        s.catalogLoading) {
      return;
    }
    _qrGrace ??= Timer(const Duration(seconds: 8), () {
      _qrGrace = null;
      if (!mounted) return;
      final st = widget.state;
      if (st.remoteConnected ||
          !st.autoQr ||
          _qrSuppressed ||
          _qrOpen ||
          st.catalogLoading) {
        return;
      }
      _showRemoteDialog(context, st);
    });
  }

  void _scrollToFocused({required bool animated}) {
    final s = widget.state;
    if (s.zone != FocusZone.grid) return;
    final key =
        _tileKeys.putIfAbsent(s.gridIndex, () => GlobalKey());
    final ctx = key.currentContext;
    if (ctx == null) return;
    if (animated && !_firstFrame) {
      Scrollable.ensureVisible(ctx,
          alignment: 0.35,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic);
    } else {
      Scrollable.ensureVisible(ctx, alignment: 0.35);
    }
  }

  bool _isOkKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.space;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final s = widget.state;
    if (e is KeyDownEvent) {
      if (_isOkKey(e.logicalKey)) {
        // Arm long-press favourite; ignore auto-repeat downs.
        if (_okDownAt == null) {
          _okDownAt = DateTime.now();
          _okLongFired = false;
          _okTimer?.cancel();
          _okTimer = Timer(
              const Duration(milliseconds: 550), () {
            if (!mounted || _okDownAt == null) return;
            _okLongFired = true;
            final f = s.focusedChannel;
            if (f != null && s.zone == FocusZone.grid) {
              s.toggleFavourite(f.id);
              _showToast(s.isFav(f.id)
                  ? '★ Added to Favourites'
                  : '☆ Removed from Favourites');
            }
          });
        }
        return KeyEventResult.handled;
      }
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
      if (e.logicalKey == LogicalKeyboardKey.escape ||
          e.logicalKey == LogicalKeyboardKey.goBack) {
        s.handleKey(RemoteKey.back);
        return KeyEventResult.handled;
      }
      // Tap-only favourite for PC testing (and any keyboard): holding
      // Enter/OK triggers Windows key-repeat, which trips a Flutter
      // debug assertion — this key never needs a hold.
      if (e.logicalKey == LogicalKeyboardKey.keyF) {
        final f = s.focusedChannel;
        if (f != null && s.zone == FocusZone.grid) {
          s.toggleFavourite(f.id);
          _showToast(s.isFav(f.id)
              ? '★ Added to Favourites'
              : '☆ Removed from Favourites');
        }
        return KeyEventResult.handled;
      }
      // Borderless fullscreen on desktop windowed builds (no-op on Pi).
      if (e.logicalKey == LogicalKeyboardKey.f11) {
        s.handleKey(RemoteKey.fullscreen);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (e is KeyUpEvent && _isOkKey(e.logicalKey)) {
      final wasLong = _okLongFired;
      _okDownAt = null;
      _okLongFired = false;
      _okTimer?.cancel();
      if (!wasLong) s.handleKey(RemoteKey.ok); // short press
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showToast(String msg) {
    _toastTimer?.cancel();
    setState(() => _toast = msg);
    _toastTimer = Timer(
        const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  /// Remote icon keys (picked in the web UI) mapped to Heroicons.
  /// Unknown keys fall back to tv — never crash on user data.
  static const _listIcons = <String, HeroIcons>{
    'tv': HeroIcons.tv,
    'film': HeroIcons.film,
    'trophy': HeroIcons.trophy,
    'musicalNote': HeroIcons.musicalNote,
    'newspaper': HeroIcons.newspaper,
    'faceSmile': HeroIcons.faceSmile,
    'globeAlt': HeroIcons.globeAlt,
    'flag': HeroIcons.flag,
    'radio': HeroIcons.radio,
    'star': HeroIcons.star,
    'heart': HeroIcons.heart,
    'bolt': HeroIcons.bolt,
    'sparkles': HeroIcons.sparkles,
    'ticket': HeroIcons.ticket,
    'play': HeroIcons.play,
    'home': HeroIcons.home,
    'rss': HeroIcons.rss,
    'signal': HeroIcons.signal,
    'clock': HeroIcons.clock,
    'moon': HeroIcons.moon,
    'sun': HeroIcons.sun,
    'cloud': HeroIcons.cloud,
    'bookOpen': HeroIcons.bookOpen,
    'bookmark': HeroIcons.bookmark,
    'gift': HeroIcons.gift,
    'cake': HeroIcons.cake,
    'photo': HeroIcons.photo,
    'videoCamera': HeroIcons.videoCamera,
    'microphone': HeroIcons.microphone,
    'phone': HeroIcons.phone,
    'users': HeroIcons.users,
    'user': HeroIcons.user,
    'briefcase': HeroIcons.briefcase,
    'academicCap': HeroIcons.academicCap,
    'map': HeroIcons.map,
    'wallet': HeroIcons.wallet,
    'cog6Tooth': HeroIcons.cog6Tooth,
  };

  static HeroIcons listIconFor(String key) =>
      _listIcons[key] ?? HeroIcons.tv;

  HeroIcons _sideIcon(SideItem item, int index, AppState s) {
    if (index == 0) return HeroIcons.star;
    // User list: remote-picked icon. Built-ins: keyword matching.
    final pl = s.playlistForRail(item.key);
    if (pl != null) return listIconFor(pl.icon);
    final t = item.label.toLowerCase();
    if (t.contains('india')) return HeroIcons.flag;
    if (t.contains('global')) return HeroIcons.globeAlt;
    if (t.contains('news')) return HeroIcons.newspaper;
    if (t.contains('sport')) return HeroIcons.trophy;
    if (t.contains('music')) return HeroIcons.musicalNote;
    if (t.contains('kid')) return HeroIcons.faceSmile;
    if (t.contains('movie')) return HeroIcons.film;
    return HeroIcons.tv;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    // Responsive columns for the grid; feeds D-pad up/down math.
    final cols = ((MediaQuery.sizeOf(context).width -
                _kSideW -
                72) /
            200)
        .clamp(4, 8)
        .floor();
    if (s.gridColumns != cols) s.gridColumns = cols;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, e) => _onKey(node, e),
      child: Scaffold(
        backgroundColor: _kPanel,
        body: SafeArea(
          child: s.catalogLoading
              ? _loading(s)
              : Stack(
                  children: [
                    Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.stretch,
                      children: [
                        _sidebar(context, s),
                        Expanded(
                            child: _content(
                                context, s, cols)),
                      ],
                    ),
                    if (_toast != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 30,
                        child: Center(
                          child: AnimatedOpacity(
                            opacity:
                                _toast != null ? 1 : 0,
                            duration: const Duration(
                                milliseconds: 200),
                            child: Container(
                              padding:
                                  const EdgeInsets
                                      .symmetric(
                                      horizontal: 22,
                                      vertical: 13),
                              decoration: BoxDecoration(
                                  color: const Color(
                                      0xF222222B),
                                  borderRadius:
                                      BorderRadius
                                          .circular(
                                              999),
                                  border: Border.all(
                                      color: const Color(
                                          0x33FFFFFF))),
                              child: Text(_toast!,
                                  style:
                                      const TextStyle(
                                          color:
                                              _kPaper,
                                          fontSize:
                                              14.5,
                                          fontWeight:
                                              FontWeight
                                                  .w600)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  // ── Loading ──────────────────────────────────────────────────────
  Widget _loading(AppState s) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo.png',
              width: 78,
              height: 78,
              fit: BoxFit.contain,
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
                      _kAccent)),
            ),
            const SizedBox(height: 12),
            Text(s.catalogStatus,
                style: const TextStyle(
                    color: _kMuted, fontSize: 14)),
          ],
        ),
      );

  // ── Sidebar ──────────────────────────────────────────────────────
  Widget _sidebar(BuildContext context, AppState s) {
    final items = s.sideItems;
    final inSide = s.zone == FocusZone.sidebar;
    return Container(
      width: _kSideW,
      color: _kSide,
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                20, 24, 20, 14),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius:
                      BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 40,
                    height: 40,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('OpenTV',
                          style: TextStyle(
                              color: _kPaper,
                              fontSize: 21,
                              fontWeight:
                                  FontWeight.w800,
                              letterSpacing: -0.3)),
                      SizedBox(height: 2),
                      Text(
                          'One time investment, lifetime enjoyment',
                          maxLines: 2,
                          overflow:
                              TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _kMuted,
                              fontSize: 10.5,
                              fontWeight:
                                  FontWeight.w500)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding:
                  const EdgeInsets.symmetric(
                      horizontal: 12),
              itemCount: items.length,
              itemBuilder: (c, i) {
                final active = s.sideIndex == i;
                final focused = inSide && active;
                // Custom lists show their picked icon (in its picked color
                // when selected) and never the ★ prefix.
                final pl = i == 0
                    ? null
                    : s.playlistForRail(items[i].key);
                final label = items[i].label.startsWith('★ ')
                    ? items[i].label.substring(2)
                    : items[i].label;
                final iconColor = !active
                    ? _kMuted
                    : (pl != null
                        ? Color(pl.color)
                        : (focused
                            ? _kAccent
                            : _kPaper));
                // Just reordered from the phone remote: flash gold once
                // (AppState self-clears the flag; AnimatedContainer
                // eases both in and out).
                final moved =
                    s.lastMovedRailKey != null &&
                        s.lastMovedRailKey ==
                            items[i].key;
                return Padding(
                  padding: const EdgeInsets.only(
                      bottom: 4),
                  child: GestureDetector(
                    onTap: () => s.selectSide(i),
                    child: AnimatedScale(
                      // Selected category pops slightly.
                      scale: active ? 1.045 : 1.0,
                      duration: const Duration(
                          milliseconds: 180),
                      curve: Curves.easeOut,
                      child: AnimatedContainer(
                        duration: const Duration(
                            milliseconds: 180),
                      padding:
                          const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 13),
                      decoration: BoxDecoration(
                        color: moved
                            ? const Color(0x33FFB338)
                            : active
                                ? const Color(
                                    0xFF1B1B22)
                                : Colors.transparent,
                        borderRadius:
                            BorderRadius.circular(4),
                        border: moved
                            ? Border.all(
                                color: const Color(
                                    0xFFFFB338),
                                width: 1.5)
                            : null,
                        // Selected category carries a soft blue glow.
                        boxShadow: active
                            ? const [
                                BoxShadow(
                                    color: Color(
                                        0x663D9BFF),
                                    blurRadius: 20,
                                    spreadRadius: 1,
                                    offset:
                                        Offset(0, 3)),
                              ]
                            : null,
                      ),
                      child: Row(
                        children: [
                          HeroIcon(
                              pl != null
                                  ? listIconFor(pl.icon)
                                  : _sideIcon(
                                      items[i], i, s),
                              size: 21,
                              color: iconColor),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(label,
                                maxLines: 1,
                                overflow: TextOverflow
                                    .ellipsis,
                                style: TextStyle(
                                    color: active
                                        ? _kPaper
                                        : _kMuted,
                                    fontSize: 15,
                                    fontWeight:
                                        FontWeight
                                            .w600)),
                          ),
                          AnimatedSlide(
                            offset: active
                                ? Offset.zero
                                : const Offset(0.5, 0),
                            duration: const Duration(
                                milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            child: AnimatedOpacity(
                              opacity: active ? 1 : 0,
                              duration: const Duration(
                                  milliseconds: 200),
                            child: HeroIcon(
                                HeroIcons.chevronRight,
                                size: 20,
                                color: focused
                                    ? _kAccent
                                    : _kPaper),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.stretch,
              children: [
                GestureDetector(
                  onTap: () =>
                      _showRemoteDialog(context, s),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 13),
                    decoration: BoxDecoration(
                        color: const Color(
                            0xFF1B1B22),
                        borderRadius:
                            BorderRadius.circular(
                                12)),
                    child: const Row(
                      children: [
                        HeroIcon(
                            HeroIcons.qrCode,
                            size: 21,
                            color: _kMuted),
                        SizedBox(width: 12),
                        Text('Phone Remote',
                            style: TextStyle(
                                color: _kPaper,
                                fontSize: 15,
                                fontWeight:
                                    FontWeight
                                        .w600)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Center(child: ClockText()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Right content ────────────────────────────────────────────────
  Widget _content(
      BuildContext context, AppState s, int cols) {
    final list = s.sidebarChannels;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Cinematic photo backdrop — fixed while the grid scrolls above.
        Image.asset(
          'assets/images/bg.png',
          fit: BoxFit.cover,
          alignment: Alignment.centerRight,
        ),
        // Dark overlay: text stays readable, tiles glow through it.
        // Heavier toward the bottom where the tiles stack up.
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x9E08080B),
                  Color(0xD608080B),
                ]),
          ),
        ),
        Column(
          crossAxisAlignment:
              CrossAxisAlignment.stretch,
          children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              28, 24, 28, 6),
          child: Row(
            children: [
              // Sole flex: hugs the left; the inner min-row keeps the
              // count glued to the title while the title still
              // ellipsizes when long. (A bare Flexible here would
              // default to flex:1 and split free space with Spacer,
              // stranding the clock mid-bar.)
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(s.sideTitle,
                          maxLines: 1,
                          overflow:
                              TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: _kPaper,
                              fontSize: 26,
                              fontWeight:
                                  FontWeight.w800,
                              letterSpacing: -0.4)),
                    ),
                    const SizedBox(width: 10),
                    Padding(
                      padding:
                          const EdgeInsets.only(
                              top: 8),
                      child: Text(
                          '${list.length} channels',
                          maxLines: 1,
                          style: const TextStyle(
                              color: _kPaper,
                              fontSize: 12.5,
                              fontWeight:
                                  FontWeight.w600)),
                    ),
                  ],
                ),
              ),
              const HeaderClock(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              28, 0, 28, 14),
          child: Text(
              s.zone == FocusZone.sidebar
                  ? '↑↓ categories • → channels'
                  : '↑↓←→ move • OK play • hold OK/F ★ • ← sidebar • CH +/− zap',
              style: const TextStyle(
                  color: _kPaper,
                  fontSize: 12.5)),
        ),
        Expanded(
          child: list.isEmpty
              ? _emptyFav()
              : GridView.builder(
                  controller: _gridCtrl,
                  padding:
                      const EdgeInsets.fromLTRB(
                          28, 30, 28, 30),
                  gridDelegate:
                      SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.62,
                  ),
                  itemCount: list.length,
                  itemBuilder: (c, j) {
                    final ch = list[j];
                    final isFocus =
                        s.zone == FocusZone.grid &&
                            s.gridIndex == j;
                    return RepaintBoundary(
                      key: _tileKeys.putIfAbsent(
                          j, () => GlobalKey()),
                      child: _tile(
                          ch,
                          isFocus,
                          s.healthById[ch.id] ??
                              'unknown',
                          s.isFav(ch.id),
                          () =>
                              widget.onPlay(ch)),
                    );
                  },
                ),
        ),
            ],
          ),
        ],
      );
  }

  Widget _emptyFav() => const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('☆',
                  style: TextStyle(
                      fontSize: 44,
                      color: _kMuted)),
              SizedBox(height: 12),
              Text('No favourites yet',
                  style: TextStyle(
                      color: _kPaper,
                      fontSize: 19,
                      fontWeight:
                          FontWeight.w700)),
              SizedBox(height: 6),
              Text(
                  'Hold OK on any channel — or tap ★ on your phone.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _kMuted,
                      fontSize: 13.5)),
            ],
          ),
        ),
      );

  // ── Grid tile (4px, thin light-blue border + big blue halo) ───────
  Widget _tile(
          TvChannel ch,
          bool isFocus,
          String health,
          bool fav,
          VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: AnimatedScale(
          scale: isFocus ? 1.05 : 1.0,
          duration:
              const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(
                milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              // Glass tile: the photo backdrop glows faintly through.
              color: const Color(0xA817171B),
              borderRadius:
                  BorderRadius.circular(4),
              border: Border.all(
                  color: isFocus
                      ? const Color(0xCC3D9BFF)
                      : Colors.transparent,
                  width: 1.5),
              boxShadow: isFocus
                  ? const [
                      BoxShadow(
                          color:
                              Color(0x883D9BFF),
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
                      const EdgeInsets.fromLTRB(
                          18, 18, 18, 64),
                  child: ch.logoUrl.isEmpty
                      ? const HeroIcon(
                          HeroIcons.tv,
                          color: _kPaper,
                          size: 40)
                      : CachedNetworkImage(
                          imageUrl: ch.logoUrl,
                          memCacheWidth: 360,
                          fit: BoxFit.contain,
                          fadeInDuration:
                              const Duration(
                                  milliseconds:
                                      200),
                          errorWidget: (context, url,
                                  error) =>
                              const HeroIcon(
                                  HeroIcons.tv,
                                  color: _kPaper,
                                  size: 40),
                        ),
                ),
                if (fav)
                  const Positioned(
                    top: 8,
                    right: 8,
                    child: HeroIcon(
                        HeroIcons.star,
                        color: _kAccent,
                        size: 18,
                        style: HeroIconStyle.solid),
                  ),
                if (health == 'slow' ||
                    health == 'dead')
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                        width: 8,
                        height: 8,
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
                            12, 24, 12, 11),
                    decoration:
                        const BoxDecoration(
                      gradient: LinearGradient(
                          begin:
                              Alignment.topCenter,
                          end: Alignment
                              .bottomCenter,
                          colors: [
                            Colors.transparent,
                            Color(0xE6000000)
                          ]),
                    ),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
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
                                      color: _kLive,
                                      fontSize: 10,
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
                                    fontSize: 14,
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
                                    fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  bool _isLive(TvChannel? ch) {
    if (ch == null) return false;
    final t =
        '${ch.category} ${ch.name}'.toLowerCase();
    return t.contains('news') ||
        t.contains('live') ||
        t.contains('sports');
  }

  // ── QR dialog: minimal, bigger, 8px radii ──────────────────────────
  void _showRemoteDialog(
      BuildContext context, AppState s) {
    final urls =
        s.lanUrls.isNotEmpty ? s.lanUrls : ['http://127.0.0.1:8080/remote'];
    _qrOpen = true;
    showDialog(
      context: context,
      builder: (_) => _RemoteDialog(
          urls: urls,
          channels: s.allChannels.length,
          lists: s.customPlaylists.length),
    ).then((_) {
      _qrOpen = false;
      // Manual Done stays shut for this outage; auto-dismiss (a phone
      // just linked) does not suppress the next one.
      if (!_qrAutoClosed) _qrSuppressed = true;
      _qrAutoClosed = false;
      // Hand keyboard focus back (PC testing) once the dialog is gone.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    });
  }
}

/// QR dialog: compact (never full-width), one QR per reachable address
/// side by side with its URL in small text underneath — scan whichever
/// your phone can reach.
class _RemoteDialog extends StatelessWidget {
  final List<String> urls;
  final int channels;
  final int lists;
  const _RemoteDialog(
      {required this.urls,
      required this.channels,
      required this.lists});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF101014),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8)),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Phone Remote',
                  style: TextStyle(
                      color: _kPaper,
                      fontSize: 20,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('Same Wi-Fi • scan one',
                  style: TextStyle(
                      color: _kMuted, fontSize: 13)),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 20,
                runSpacing: 18,
                children: [
                  for (final u in urls)
                    SizedBox(
                      width: 168,
                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          Container(
                            padding:
                                const EdgeInsets.all(
                                    10),
                            decoration: BoxDecoration(
                                color: _kPaper,
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                            8)),
                            child: QrImageView(
                                data: u, size: 148),
                          ),
                          const SizedBox(height: 8),
                          Text(u,
                              maxLines: 2,
                              overflow: TextOverflow
                                  .ellipsis,
                              textAlign:
                                  TextAlign.center,
                              style: const TextStyle(
                                  color: _kMuted,
                                  fontSize: 10.5)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                  '$channels channels • $lists saved lists',
                  style: const TextStyle(
                      color: _kMuted,
                      fontSize: 12.5)),
              const SizedBox(height: 18),
              GestureDetector(
                onTap: () =>
                    Navigator.of(context).pop(),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(
                          horizontal: 40,
                          vertical: 13),
                  decoration: BoxDecoration(
                      color: _kAccent,
                      borderRadius:
                          BorderRadius.circular(
                              8)),
                  child: const Text('Done',
                      style: TextStyle(
                          color: Colors.white,
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
}

/// Small live clock for the sidebar foot.
class ClockText extends StatefulWidget {
  const ClockText({super.key});
  @override
  State<ClockText> createState() =>
      _ClockTextState();
}

class _ClockTextState extends State<ClockText> {
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
    final hh =
        now.hour.toString().padLeft(2, '0');
    final mm =
        now.minute.toString().padLeft(2, '0');
    return Text('$hh:$mm',
        style: const TextStyle(
            color: _kMuted,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFeatures: [
              FontFeature.tabularFigures()
            ]));
  }
}

/// Modular date + time block for the content header — two quiet pills
/// (date | time) with tabular figures. Ticks every 30s; cheap on Pi.
class HeaderClock extends StatefulWidget {
  const HeaderClock({super.key});
  @override
  State<HeaderClock> createState() =>
      _HeaderClockState();
}

class _HeaderClockState extends State<HeaderClock> {
  static const _days = [
    'MON',
    'TUE',
    'WED',
    'THU',
    'FRI',
    'SAT',
    'SUN'
  ];
  static const _mos = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC'
  ];
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
    final hh =
        now.hour.toString().padLeft(2, '0');
    final mm =
        now.minute.toString().padLeft(2, '0');
    // One modular block pinned to the right edge: small time over
    // bigger date, both right-aligned with tabular figures.
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 15, vertical: 9),
      decoration: BoxDecoration(
          color: const Color(0xFF1B1B22),
          borderRadius:
              BorderRadius.circular(12),
          border: Border.all(
              color: const Color(0x22FFFFFF))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            CrossAxisAlignment.end,
        children: [
          Text('$hh:$mm',
              style: const TextStyle(
                  color: _kAccent,
                  fontSize: 12,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [
                    FontFeature.tabularFigures()
                  ])),
          const SizedBox(height: 3),
          Text(
              '${_days[now.weekday - 1]} • ${now.day} ${_mos[now.month - 1]}',
              style: const TextStyle(
                  color: _kPaper,
                  fontSize: 15,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [
                    FontFeature.tabularFigures()
                  ])),
        ],
      ),
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
