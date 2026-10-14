// OpenTV-RPI — India-first free TV for Raspberry Pi 4 + flutter-pi.
// Single executable: TV UI + inbuilt phone-remote server (same pattern as
// FoodWastage LocalAdminServer). Phone opens http://<pi-ip>:8080/remote.
// Performance: release + mpv hw decode + capped rails + transform-only anims.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutterpi_gstreamer_video_player/flutterpi_gstreamer_video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'models/tv_channel.dart';
import 'services/app_state.dart';
import 'services/catalog_service.dart';
import 'services/custom_playlist_store.dart';
import 'services/local_remote_server.dart';
import 'services/pi_detector.dart';
import 'services/player_service.dart';
import 'ui/player_screen.dart';
import 'ui/tv_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On flutter-pi the video texture comes from flutter-pi's own gstreamer
  // plugin (media_kit has no native side there — see PlayerService). Must
  // register before any VideoPlayerController is created. No-op guarded:
  // desktop never calls this, so Windows/Linux-dev builds are unaffected.
  if (isFlutterPi) {
    try {
      FlutterpiVideoPlayer.registerWith();
    } catch (e) {
      debugPrint('flutter-pi video plugin register failed: $e');
    }
  }
  // Desktop window controls (Windows / Linux desktop): borderless
  // fullscreen for the remote's ⛶ button + F11. Skipped on flutter-pi (no
  // window manager in a custom embedder — the calls would just throw).
  if (!isFlutterPi) {
    try {
      await windowManager.ensureInitialized();
      // Wait until the native window is ready before showing it: calling
      // setFullScreen on a not-yet-shown window saves a garbage restore
      // rect in the native plugin and can leave the app hidden forever
      // ("running in Task Manager, nowhere else").
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1280, 720),
          minimumSize: Size(960, 600),
          center: true,
          title: 'OpenTV',
        ),
      );
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('window manager unavailable: $e');
    }
  }
  // Bound image memory: LRU of ~120 posters / 32MB so hundred-channel
  // rails can never grow the raster cache without limit on the Pi.
  PaintingBinding.instance.imageCache.maximumSize = 120;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 << 20;
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final state = AppState();
  final player = PlayerService();
  await player.init(state);

  // Fullscreen applier (desktop only — Pi keeps the null applier, making
  // every toggle a harmless state flip).
  //
  // Why this is a serialized + verifying wrapper instead of a bare
  // `setFullScreen(v)`:
  //  - window_manager 0.5.2 skips its native work when the window is
  //    already frameless or started maximized → title bar survives and the
  //    window is not edge-to-edge on some machines. Unmaximizing first
  //    forces the frameless path, and isFullScreen() verifies the result.
  //  - Overlapping enter/exit calls corrupt the saved restore rect, which
  //    is how the window ended up invisible-but-alive in Task Manager.
  //    One transition runs at a time; rapid remote double-taps coalesce
  //    into the latest intent.
  //  - Every path ends with show()+focus() so a failed transition can
  //    never strand a hidden window.
  bool fsBusy = false;
  bool? fsPending;
  Future<void> applyFullscreen(bool want) async {
    if (isFlutterPi) return;
    if (fsBusy) {
      fsPending = want;
      return;
    }
    fsBusy = true;
    var target = want;
    try {
      while (true) {
        try {
          // Never restyle a hidden window.
          try {
            await windowManager.show();
          } catch (_) {}
          if (target) {
            try {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
                await Future.delayed(
                    const Duration(milliseconds: 150));
              }
            } catch (_) {}
            try {
              await windowManager.focus();
            } catch (_) {}
            await windowManager.setFullScreen(true);
            await Future.delayed(
                const Duration(milliseconds: 150));
            var ok = true;
            try {
              ok = await windowManager.isFullScreen();
            } catch (_) {}
            if (!ok) {
              // Desync (usually a stale frameless flag in the plugin):
              // force the frameless path once and retry.
              try {
                await windowManager.setAsFrameless();
                await Future.delayed(
                    const Duration(milliseconds: 100));
                await windowManager.setFullScreen(true);
                await Future.delayed(
                    const Duration(milliseconds: 150));
              } catch (_) {}
            }
            try {
              await windowManager.focus();
            } catch (_) {}
          } else {
            await windowManager.setFullScreen(false);
            await Future.delayed(
                const Duration(milliseconds: 150));
            try {
              await windowManager.show();
              await windowManager.focus();
            } catch (_) {}
            try {
              if (await windowManager.isFullScreen()) {
                await windowManager.setFullScreen(false);
                await windowManager.show();
              }
            } catch (_) {}
          }
        } catch (e) {
          debugPrint('setFullScreen failed: $e');
          try {
            await windowManager.show();
          } catch (_) {}
        }
        if (fsPending == null) break;
        target = fsPending!;
        fsPending = null;
      }
    } finally {
      fsBusy = false;
    }
  }

  state.fullscreenApplier = applyFullscreen;
  // Restore the last choice only AFTER the first frame is on screen: the
  // native plugin snapshots the window rect on enter, and entering before
  // Show() snapshots garbage → unrestorable invisible window.
  bool wantFullscreen = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    wantFullscreen = prefs.getBool('opentv_fullscreen') ?? false;
  } catch (_) {}

  // Phone-remote server must not block boot — fire and forget.
  // ignore: unawaited_futures
  LocalRemoteServer.start(state, wantPort: 8080);
  LocalRemoteServer.attachPlayer(player);

  runApp(OpenTvApp(state: state, player: player));

  // Deferred fullscreen restore: the native plugin snapshots the window
  // rect on enter, so entering before Show()/first-frame snapshots garbage
  // and the window can never be restored (invisible-but-alive hang).
  if (wantFullscreen && !isFlutterPi) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 600));
      try {
        await state.setFullscreen(true);
      } catch (_) {}
    });
  }

  // Catalog after first frame so TV paints instantly, then fills in.
  // Saved pasted lists load first so they appear even if network is slow.
  state.setCatalogLoading('Finding free India channels…');
  state.setCustomPlaylists(await CustomPlaylistStore.load());
  await state.loadFavourites();
  final (channels, rails) = await CatalogService.load();
  state.setCatalog(channels, rails,
      status: channels.isEmpty
          ? 'No network — showing saved picks'
          : '${channels.length} free channels ready');

  // Stream-health probing DISABLED (was: cached apply + 12-way concurrent
  // background probe of every origin). Reason: probes open real connections
  // to the same servers playback uses — on throttling panel origins those
  // extra sockets read as abuse and get the playback connection throttled /
  // blocked, and on the Pi they contend for bandwidth mid-tune-in. Channels
  // dying right after working fits that signature. Dots stay neutral grey
  // ('unknown'), rails keep catalog (name) order. Re-enable only with a
  // gentler prober (sequential, off-peak, player-aware) — see
  // StreamHealth.enabled.
  //
  // state.applyHealth(
  //     await StreamHealth.cachedHealth(state.allChannels));
  // StreamHealth.probeChannels(state.allChannels)
  //     .then(state.applyHealth)
  //     .catchError((_) {});

  // Background heal: refetch pasted lists so lists saved under the old
  // 300-channel cap (or with dead links) refresh to their full contents.
  // Failures are silent — the cached copy stays.
  for (final pl in state.customPlaylists) {
    CatalogService.fetchCustomM3U(pl.url,
            idPrefix: pl.id, category: pl.name)
        .then((fresh) {
      state.upsertCustomPlaylist(
          pl.copyWith(channels: fresh));
      CustomPlaylistStore.saveAll(state.customPlaylists);
    }).catchError((_) {});
  }
}

class OpenTvApp extends StatelessWidget {
  final AppState state;
  final PlayerService player;
  const OpenTvApp(
      {super.key, required this.state, required this.player});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenTV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        // Global typeface: bundled GoogleSans (same files as FoodWastage).
        fontFamily: 'GoogleSans',
        scaffoldBackgroundColor: const Color(0xFF0B0B0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFB338),
          surface: Color(0xFF0B0B0F),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(
              color: Color(0xFFF5F1E8), fontWeight: FontWeight.w800),
          bodyMedium: TextStyle(color: Color(0xFFF5F1E8)),
        ),
        // One thin, light, pill-shaped scrollbar everywhere (sidebar
        // list, channel grid, dialogs): 4px thumb, no track, auto-fade.
        scrollbarTheme: ScrollbarThemeData(
          thickness: WidgetStatePropertyAll(4.0),
          radius: Radius.circular(999),
          thumbColor: WidgetStatePropertyAll(Color(0x47FFFFFF)),
          trackColor: WidgetStatePropertyAll(Colors.transparent),
          trackBorderColor:
              WidgetStatePropertyAll(Colors.transparent),
          crossAxisMargin: 3.0,
          mainAxisMargin: 6.0,
          minThumbLength: 36.0,
          thumbVisibility: WidgetStatePropertyAll(false),
          trackVisibility: WidgetStatePropertyAll(false),
          interactive: true,
        ),
      ),
      home: ListenableBuilder(
        listenable: state,
        builder: (context, child) {
          // Stay on the player screen while loading / erroring too —
          // AppState.stop() clears `playing` on Back/Home.
          // AnimatedSwitcher gives the cinematic open/close: fade + rise.
          final playing = state.playing;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (kid, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween(begin: 0.965, end: 1.0)
                    .animate(anim),
                child: SlideTransition(
                  position: Tween(
                          begin: const Offset(0, 0.035),
                          end: Offset.zero)
                      .animate(anim),
                  child: kid,
                ),
              ),
            ),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.center,
              children: [...previous, ?current],
            ),
            child: playing != null
                ? PlayerScreen(
                    key: const ValueKey('player'),
                    state: state,
                    player: player)
                : TvHome(
                    key: const ValueKey('home'),
                    state: state,
                    onPlay: (TvChannel ch) =>
                        player.playChannel(ch),
                  ),
          );
        },
      ),
    );
  }
}
