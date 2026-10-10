// Why this file exists: flutter-pi is NOT the standard Flutter Linux
// embedder. It runs the Dart bundle (flutter_assets/) on its own
// KMS/DRM engine and never builds linux/runner — so NONE of the Linux
// plugin native code (media_kit_video textures, path_provider, etc.)
// is present on the Pi. media_kit's Dart FFI to libmpv still demuxes
// (the "tank" fills), but video frames have nowhere to go: no Texture
// is ever registered, vo=gpu render fails, width/playing signals never
// resolve — hence infinite "CONNECTING / Still connecting" on the Pi
// while Windows (full embedder + bundled libmpv + ANGLE textures) is
// fine. The official flutter-pi video path is video_player +
// flutterpi_gstreamer_video_player (gstreamer playbin, HW decode,
// inline texture). PlayerService picks the backend with this detector.
import 'dart:io';

// Compile-time override for the Pi bundle:
//   flutterpi_tool build --release --cpu=pi4 --dart-define=OPENTV_PI=true
// (flutterpi_tool forwards --dart-define to the flutter build.)
const bool _forcePi = bool.fromEnvironment('OPENTV_PI', defaultValue: false);
const bool _forceMpv =
    bool.fromEnvironment('OPENTV_FORCE_MPV', defaultValue: false);

/// True when running inside flutter-pi on a Raspberry Pi (or when forced
/// via --dart-define=OPENTV_PI=true). Desktop Linux / Windows stay false
/// so dev machines keep the media_kit backend.
bool get isFlutterPi {
  if (_forceMpv) return false;
  if (_forcePi) return true;
  // Env override for SSH testing without rebuilding:
  //   OPENTV_PI=1 flutter-pi --release flutter_assets/
  try {
    final env = Platform.environment['OPENTV_PI'] ?? '';
    if (env == '1' || env.toLowerCase() == 'true') return true;
    if ((Platform.environment['OPENTV_FORCE_MPV'] ?? '') == '1') {
      return false;
    }
  } catch (_) {}
  try {
    if (!Platform.isLinux) return false;
  } catch (_) {
    return false;
  }
  // Standard desktop embedder (X11/Wayland session) is NEVER flutter-pi —
  // even on Raspberry Pi hardware. flutter-pi runs on the bare console
  // with no display server; a kiosk/desktop session always sets one of
  // these. Must come before the hardware fingerprints below (device-tree
  // says "Raspberry" on desktop Pi OS too).
  try {
    if (Platform.environment['DISPLAY'] != null ||
        Platform.environment['WAYLAND_DISPLAY'] != null) {
      return false;
    }
  } catch (_) {}
  // Pi fingerprints (all best-effort, never throws):
  //  - /proc/device-tree/model contains "Raspberry Pi"
  //  - flutter-pi binary on PATH / installed location
  try {
    final model = File('/proc/device-tree/model');
    if (model.existsSync()) {
      final text = model.readAsStringSync();
      if (text.toLowerCase().contains('raspberry')) return true;
    }
  } catch (_) {}
  try {
    for (final p in [
      '/usr/bin/flutter-pi',
      '/usr/local/bin/flutter-pi',
      '/home/pi/flutter-pi/flutter-pi',
    ]) {
      try {
        if (File(p).existsSync()) return true;
      } catch (_) {}
    }
  } catch (_) {}
  // Last resort: ARM Linux without X11/Wayland display servers smells
  // like a flutter-pi console boot (DISPLAY/WAYLAND_DISPLAY unset).
  try {
    final machine = Platform.version.toLowerCase();
    final noDisplay = Platform.environment['DISPLAY'] == null &&
        Platform.environment['WAYLAND_DISPLAY'] == null;
    if (noDisplay &&
        (machine.contains('arm') || machine.contains('aarch64'))) {
      return true;
    }
  } catch (_) {}
  return false;
}
