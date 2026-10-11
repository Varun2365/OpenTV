// Remote key vocabulary shared by: physical keys, phone WebSocket, REST.
// Keep this file dependency-free so both UI and server import it.
enum RemoteKey {
  up,
  down,
  left,
  right,
  ok,
  back,
  home,
  playPause,
  volUp,
  volDown,
  mute,
  channelUp,
  channelDown,
  fullscreen,
}

RemoteKey? remoteKeyFromString(String s) {
  switch (s.toLowerCase().trim()) {
    case 'up':
      return RemoteKey.up;
    case 'down':
      return RemoteKey.down;
    case 'left':
      return RemoteKey.left;
    case 'right':
      return RemoteKey.right;
    case 'ok':
    case 'enter':
    case 'select':
      return RemoteKey.ok;
    case 'back':
    case 'escape':
      return RemoteKey.back;
    case 'home':
      return RemoteKey.home;
    case 'playpause':
    case 'play_pause':
    case 'play-pause':
    case 'space':
      return RemoteKey.playPause;
    case 'volup':
    case 'vol_up':
    case 'volumeup':
      return RemoteKey.volUp;
    case 'voldown':
    case 'vol_down':
    case 'volumedown':
      return RemoteKey.volDown;
    case 'mute':
      return RemoteKey.mute;
    case 'fullscreen':
    case 'f11':
      return RemoteKey.fullscreen;
    case 'chup':
    case 'channelup':
      return RemoteKey.channelUp;
    case 'chdown':
    case 'channeldown':
      return RemoteKey.channelDown;
    default:
      return null;
  }
}
