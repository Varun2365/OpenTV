import 'package:flutter_test/flutter_test.dart';

import 'package:opentv_rpi/models/tv_channel.dart';
import 'package:opentv_rpi/services/app_state.dart';
import 'package:opentv_rpi/services/remote_command.dart';

const _a = TvChannel(
    id: 'a', name: 'A News', streamUrl: 'http://x/a.m3u8');
const _b = TvChannel(
    id: 'b', name: 'B News', streamUrl: 'http://x/b.m3u8');

AppState _twoRail() {
  final s = AppState();
  s.setCatalog(
      [_a, _b],
      [
        ChannelRail('India • News', 'sub', [_a]),
        ChannelRail('Global • News', 'sub', [_b]),
      ]);
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
    expect(s.focusedChannel?.id, 't1');
    s.play(ch);
    expect(s.playing?.id, 't1');
    expect(s.isPlaying, true);
  });

  test('up from first rail enters pill nav, down returns', () {
    final s = _twoRail();
    expect(s.zone, FocusZone.grid);
    s.handleKey(RemoteKey.up);
    expect(s.zone, FocusZone.nav);
    s.handleKey(RemoteKey.down);
    expect(s.zone, FocusZone.grid);
    expect(s.railIndex, 0);
  });

  test('nav tabs match rails and activate jumps', () {
    final s = _twoRail();
    final labels =
        s.navTabs.map((t) => t.label).toList();
    expect(labels, containsAll(['Home', 'India', 'Global', 'News']));
    // Focus Global tab (index 2) and activate.
    s.handleKey(RemoteKey.up); // enter nav
    s.handleKey(RemoteKey.right);
    s.handleKey(RemoteKey.right);
    expect(s.navTabs[s.tabIndex].label, 'Global');
    s.handleKey(RemoteKey.ok);
    expect(s.zone, FocusZone.grid);
    expect(s.railIndex, 1);
    expect(s.focusedChannel?.id, 'b');
  });

  test('CH keys zap while watching', () {
    final s = _twoRail();
    s.play(_a);
    s.handleKey(RemoteKey.channelDown);
    expect(s.playing?.id, 'b');
    s.handleKey(RemoteKey.channelDown);
    expect(s.playing?.id, 'a'); // wraps
  });

  test('cards wrap within a rail', () {    final s = AppState();
    s.setCatalog(
        [_a, _b],
        [
          ChannelRail('One', 'sub', [_a, _b])
        ]);
    s.handleKey(RemoteKey.left); // wraps to last
    expect(s.cardIndex, 1);
    s.handleKey(RemoteKey.right); // wraps to first
    expect(s.cardIndex, 0);
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

  test('each rail remembers its own cursor', () {
    TvChannel ch(String id) => TvChannel(
        id: id, name: 'N $id', streamUrl: 'http://x/$id.m3u8');
    final r1 = [ch('a1'), ch('a2'), ch('a3')];
    final r2 = [ch('b1'), ch('b2'), ch('b3')];
    final s = AppState();
    s.setCatalog(
        [...r1, ...r2],
        [
          ChannelRail('R1', 's', r1),
          ChannelRail('R2', 's', r2),
        ]);
    s.handleKey(RemoteKey.right);
    s.handleKey(RemoteKey.right);
    expect(s.cardIndex, 2); // deep in R1
    s.handleKey(RemoteKey.down);
    expect(s.railIndex, 1);
    expect(s.cardIndex, 0); // R2 starts at its own 0, not 2
    s.handleKey(RemoteKey.right);
    expect(s.cardIndex, 1); // R2 cursor = 1
    s.handleKey(RemoteKey.up);
    expect(s.railIndex, 0);
    expect(s.cardIndex, 2); // R1 restores 2
    s.handleKey(RemoteKey.down);
    expect(s.cardIndex, 1); // R2 restores 1
  });

  test('repeat rate clamps to 2..12', () {
    final s = AppState();
    s.setRepeatRate(99);
    expect(s.repeatRate, 12);
    s.setRepeatRate(0);
    expect(s.repeatRate, 2);
  });
}
