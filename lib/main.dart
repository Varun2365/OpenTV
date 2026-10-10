// OpenTV-RPI — India-first free TV for Raspberry Pi 4 + flutter-pi.
// Single executable: TV UI + inbuilt phone-remote server (same pattern as
// FoodWastage LocalAdminServer). Phone opens http://<pi-ip>:8080/remote.
// Performance: release + mpv hw decode + capped rails + transform-only anims.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/tv_channel.dart';
import 'services/app_state.dart';
import 'services/catalog_service.dart';
import 'services/custom_playlist_store.dart';
import 'services/local_remote_server.dart';
import 'services/player_service.dart';
import 'services/stream_health.dart';
import 'ui/player_screen.dart';
import 'ui/tv_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Bound image memory: LRU of ~120 posters / 32MB so hundred-channel
  // rails can never grow the raster cache without limit on the Pi.
  PaintingBinding.instance.imageCache.maximumSize = 120;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 << 20;
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final state = AppState();
  final player = PlayerService();
  await player.init(state);

  // Phone-remote server must not block boot — fire and forget.
  // ignore: unawaited_futures
  LocalRemoteServer.start(state, wantPort: 8080);
  LocalRemoteServer.attachPlayer(player);

  runApp(OpenTvApp(state: state, player: player));

  // Catalog after first frame so TV paints instantly, then fills in.
  // Saved pasted lists load first so they appear even if network is slow.
  state.setCatalogLoading('Finding free India channels…');
  state.setCustomPlaylists(await CustomPlaylistStore.load());
  final (channels, rails) = await CatalogService.load();
  state.setCatalog(channels, rails,
      status: channels.isEmpty
          ? 'No network — showing saved picks'
          : '${channels.length} free channels ready');

  // Fast streams first: cached health applies instantly, then a
  // background parallel probe re-scores everything and re-sorts once.
  state.applyHealth(
      await StreamHealth.cachedHealth(state.allChannels));
  StreamHealth.probeChannels(state.allChannels)
      .then(state.applyHealth)
      .catchError((_) {});

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
