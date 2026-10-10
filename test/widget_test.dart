import 'package:flutter_test/flutter_test.dart';

import 'package:opentv_rpi/models/tv_channel.dart';
import 'package:opentv_rpi/services/app_state.dart';
import 'package:opentv_rpi/services/remote_command.dart';

const _a = TvChannel(
    id: 'a', name: 'A News', streamUrl: 'http://x/a.m3u8');
const _b = TvChannel(
    id: 'b', name: 'B News', streamUrl: 'http://x/b.m3u8');

TvChannel _ch(String id) => TvChannel(
    id: id, name: 'N $id', streamUrl: 'http://x/$id.m3u8');

/// Favourites side item + two rails. Tests drive the grid via sideIndex.
AppState _twoRail() {
  final s = AppState();
  s.gridColumns = 6;
  s.setCatalog(
      [_a, _b],
      [
        ChannelRail('India • News', 'sub', [_a]),
        ChannelRail('Global • News', 'sub', [_b]),
      ]);
  s.selectSide(1);
  return s;
}

void main() {
  test('AppState focus + play flow', () {
    final s = AppState();
    const ch = TvChannel(
        id: 't1',
        name: 'Test News',
        streamUrl: 'http://x/y.m3u8');
    s.setCatalog(
        [ch],
        [
          ChannelRail('Test', 'sub', [ch])
        ]);
    s.selectSide(1);
    expect(s.focusedChannel?.id, 't1');
    s.play(ch);
    expect(s.playing?.id, 't1');
    expect(s.isPlaying, true);
  });

  test('sidebar <-> grid zone flow, up never jumps', () {
    final s = _twoRail();
    expect(s.zone, FocusZone.grid);
    // Left at column 0 steps back to the sidebar.
    s.handleKey(RemoteKey.left);
    expect(s.zone, FocusZone.sidebar);
    // Right dives back into the channels.
    s.handleKey(RemoteKey.right);
    expect(s.zone, FocusZone.grid);
    // Up on the top row stays in the grid (no auto-jump to sidebar).
    s.handleKey(RemoteKey.up);
    expect(s.zone, FocusZone.grid);
    expect(s.gridIndex, 0);
    // Back steps out to the sidebar.
    s.handleKey(RemoteKey.back);
    expect(s.zone, FocusZone.sidebar);
  });

  test('sidebar wraps and selects categories', () {
    final s = _twoRail();
    s.zone = FocusZone.sidebar; // sideIndex starts at 1
    s.handleKey(RemoteKey.up);
    expect(s.sideIndex, 0); // Favourites
    s.handleKey(RemoteKey.up); // wraps to last (Global)
    expect(s.sideIndex, 2);
    expect(s.sideTitle, 'Global • News');
    s.handleKey(RemoteKey.down); // wraps back to Favourites
    expect(s.sideIndex, 0);
    s.handleKey(RemoteKey.ok); // dive in (empty favs)
    expect(s.zone, FocusZone.grid);
    expect(s.sidebarChannels, isEmpty);
    expect(s.focusedChannel, isNull);
  });

  test('CH keys zap while watching', () {
    final s = _twoRail();
    s.play(_a);
    s.handleKey(RemoteKey.channelDown);
    expect(s.playing?.id, 'b');
    s.handleKey(RemoteKey.channelDown);
    expect(s.playing?.id, 'a'); // wraps
  });

  test('grid 2-D movement with columns', () {
    final s = AppState();
    s.gridColumns = 3;
    final all = [_ch('c1'), _ch('c2'), _ch('c3'), _ch('c4')];
    s.setCatalog(
        all, [ChannelRail('One', 'sub', List.of(all))]);
    s.selectSide(1);
    s.handleKey(RemoteKey.right);
    expect(s.gridIndex, 1);
    s.handleKey(RemoteKey.down); // +3 → clamps to last
    expect(s.gridIndex, 3);
    s.handleKey(RemoteKey.up); // -3 → back to 0
    expect(s.gridIndex, 0);
    s.handleKey(RemoteKey.left); // column 0 → sidebar
    expect(s.zone, FocusZone.sidebar);
  });

  test('health sort puts fast first, dead last', () {
    const c = TvChannel(
        id: 'c', name: 'C News', streamUrl: 'http://x/c.m3u8');
    final s = AppState();
    s.setCatalog(
        [_a, _b, c],
        [
          ChannelRail('All', 'sub', [_a, _b, c])
        ]);
    s.applyHealth({_a.id: 'dead', c.id: 'fast', _b.id: 'slow'});
    final ids =
        s.rails.first.channels.map((e) => e.id).toList();
    expect(ids, ['c', 'b', 'a']);
    expect(s.healthById['c'], 'fast');
  });

  test('prebuffer setting clamps + resets on play/stop', () {
    final s = AppState();
    s.setPrebufferSecs(99);
    expect(s.prebufferSecs, 30);
    s.setPrebufferSecs(-3);
    expect(s.prebufferSecs, 0);
    s.setPrebuffering(true, 2, 5);
    expect(s.prebuffering, true);
    expect(s.prebufferedSec, 2);
    s.play(_a);
    expect(s.prebuffering, false);
    expect(s.prebufferTarget, 0);
    s.setPrebuffering(true, 1, 5);
    s.stop();
    expect(s.prebuffering, false);
  });

  test('video tracks feed quality label', () {
    final s = AppState();
    s.setVideoTracks([
      {'id': 'auto', 'title': 'Auto', 'w': null, 'h': null},
      {'id': 'v1', 'title': '720p', 'w': 1280, 'h': 720},
    ], 'v1');
    expect(s.qualityLabel, '720p');
    expect(s.selectedVideoTrack, 'v1');
    s.setVideoTracks(s.videoTracks, 'auto');
    expect(s.qualityLabel, '');
  });

  test('cryptic mpv errors translate to human text', () {
    final s = AppState();
    s.setPlayError('tcp: ffurl_read returned 0xdfb9b0bb');
    expect(s.playError, contains('dropped the connection'));
    s.setPlayError('HTTP error 404 Not Found');
    expect(s.playError, contains('looks dead'));
    s.setPlayError('Error decoding audio.');
    expect(s.playError, contains('Video only'));
    s.setPlayError(null);
    expect(s.playError, isNull);
  });

  test('each category remembers its own cursor', () {
    final r1 = [_ch('a1'), _ch('a2'), _ch('a3')];
    final r2 = [_ch('b1'), _ch('b2'), _ch('b3')];
    final s = AppState();
    s.gridColumns = 6;
    s.setCatalog(
        [...r1, ...r2],
        [
          ChannelRail('R1', 's', r1),
          ChannelRail('R2', 's', r2),
        ]);
    s.selectSide(1);
    s.handleKey(RemoteKey.right);
    s.handleKey(RemoteKey.right);
    expect(s.gridIndex, 2); // deep in R1
    s.selectSide(2); // R2 starts at its own 0, not 2
    expect(s.sideIndex, 2);
    expect(s.gridIndex, 0);
    s.handleKey(RemoteKey.right);
    expect(s.gridIndex, 1); // R2 cursor = 1
    s.selectSide(1); // R1 restores 2
    expect(s.gridIndex, 2);
    s.selectSide(2); // R2 restores 1
    expect(s.gridIndex, 1);
  });

  test('repeat rate clamps to 2..12', () {
    final s = AppState();
    s.setRepeatRate(99);
    expect(s.repeatRate, 12);
    s.setRepeatRate(0);
    expect(s.repeatRate, 2);
  });

  test('favourites toggle, resolve order + remote status', () {
    final s = _twoRail();
    expect(s.favouriteChannels, isEmpty);
    expect(s.sideItems.first.label, 'Favourites');
    s.toggleFavourite('b');
    s.toggleFavourite('a');
    expect(s.favouriteIds, ['a', 'b']); // most-recent first
    expect(
        s.favouriteChannels.map((c) => c.id).toList(), ['a', 'b']);
    expect(s.isFav('a'), true);
    s.toggleFavourite('a');
    expect(s.isFav('a'), false);
    expect(s.playlistForRail('★ Sports'), isNull);
    s.setRemoteStatus(connected: true, clients: 1);
    expect(s.remoteConnected, true);
    expect(s.remoteClients, 1);
    s.setAutoQr(false);
    expect(s.autoQr, false);
  });

  test('custom list icon + color persist round-trip', () {
    final s = AppState();
    const ch = TvChannel(
        id: 'x1', name: 'X', streamUrl: 'http://x/x.m3u8');
    s.setCatalog(
        [ch],
        [
          ChannelRail('★ Sports', 's', [ch])
        ]);
    expect(s.playlistForRail('★ Sports'), isNull); // not a saved list
    expect(s.playlistForRail('India'), isNull); // built-ins have none
  });

  test('preset toggle hides built-ins, keeps user lists', () {    final s = _twoRail();
    expect(s.sideItems.length, 3); // Favourites + 2 presets
    expect(s.showPresets, true);
    s.setShowPresets(false);
    expect(
        s.sideItems.map((e) => e.label).toList(), ['Favourites']);
    expect(s.sidebarChannels, isEmpty);
    expect(s.sideTitle, 'Favourites');
    // Cursor + favourites survive the toggle.
    s.toggleFavourite('a');
    s.setShowPresets(true);
    expect(s.sideItems.length, 3);
    expect(s.isFav('a'), true);
  });

  test('stretch toggle defaults off and flips', () {
    final s = AppState();
    expect(s.stretchVideo, false);
    s.setStretchVideo(true);
    expect(s.stretchVideo, true);
    s.setStretchVideo(true); // idempotent, no crash
    expect(s.stretchVideo, true);
  });
}
