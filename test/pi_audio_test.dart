import 'package:flutter_test/flutter_test.dart';

import 'package:opentv_rpi/services/player_service.dart';
import 'package:opentv_rpi/services/remote_command.dart';

// Regression: flutter-pi played video with NO audio because both Pi
// pipelines were video-only (tank ended at appsink; the native stock path
// caps-filters audio away), and the remote VOL buttons did nothing
// audible because native setVolume is an unimplemented stub. These tests
// pin the Dart-side contract: every Pi pipeline must carry an explicit
// audio branch to a real audio sink.
void main() {
  const hls = 'https://example.com/live/stream.m3u8';
  const dash = 'https://example.com/live/stream.mpd';
  const mp4 = 'https://example.com/vod/clip.mp4';

  group('Pi tank pipeline', () {
    test('carries an audio branch to a real audio sink', () {
      final p = PlayerService.piTankPipeline(hls, 20);
      expect(p, contains('decodebin name=d'));
      expect(p, contains('audioconvert'));
      expect(p, contains('audioresample'));
      expect(p, contains('autoaudiosink'));
    });

    test('keeps the video leg on flutter-pi’s texture sink', () {
      final p = PlayerService.piTankPipeline(hls, 20);
      expect(p, contains('videoconvert'));
      expect(p, contains('appsink name=sink'));
    });

    test('never caps-filters to video-only', () {
      for (final u in [hls, dash, mp4]) {
        expect(PlayerService.piTankPipeline(u, 20),
            isNot(contains('video/x-raw')));
      }
    });

    test('selects the right demuxer and banks the tank', () {
      final h = PlayerService.piTankPipeline(hls, 20);
      expect(h, contains('hlsdemux'));
      expect(h, contains('queue2'));
      expect(h, contains('max-size-time=20000000000'));
      final d = PlayerService.piTankPipeline(dash, 15);
      expect(d, contains('dashdemux'));
      final o = PlayerService.piTankPipeline(mp4, 15);
      expect(o, isNot(contains('hlsdemux')));
      expect(o, isNot(contains('dashdemux')));
    });

    test('smuggles a browser user-agent past hotlink protection', () {
      expect(PlayerService.piTankPipeline(hls, 5),
          contains('user-agent="Mozilla/5.0'));
    });
  });

  group('Pi direct pipeline (fallback)', () {
    test('also carries the audio branch — never silent', () {
      for (final u in [hls, dash, mp4]) {
        final p = PlayerService.piDirectPipeline(u);
        expect(p, contains('decodebin name=d'));
        expect(p, contains('autoaudiosink'));
        expect(p, contains('appsink name=sink'));
        expect(p, isNot(contains('video/x-raw')));
      }
    });

    test('skips the queue2 bank, keeps demuxer selection', () {
      final p = PlayerService.piDirectPipeline(hls);
      expect(p, isNot(contains('queue2')));
      expect(p, contains('hlsdemux'));
    });
  });

  group('remote volume key plumbing', () {
    test('web-remote VOL labels resolve to volume keys', () {
      expect(remoteKeyFromString('volUp'), RemoteKey.volUp);
      expect(remoteKeyFromString('volDown'), RemoteKey.volDown);
      expect(remoteKeyFromString('mute'), RemoteKey.mute);
    });
  });
}
