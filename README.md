# OpenTV-RPI

India-first free TV for Raspberry Pi 4 + flutter-pi. One executable runs the
10-foot TV interface **and** an inbuilt phone-remote server, so any phone on
the same Wi-Fi drives the TV in real time over WebSocket (<100ms).

## What it is

- **TV UI** — sidebar categories, channel grid, favourites, fullscreen player
  with hardware decoding. Built for D-pad / keyboard couch navigation.
- **Phone remote** — a single-file web app served by the TV itself at
  `http://<pi-ip>:8080/remote`. No pairing, no accounts, no cloud.
- **Your lists** — paste any M3U link from the remote; it saves on the TV as
  a new category and survives reboot.

## Features

**TV**
- Curated free catalog (iptv-org sources, India-first) with a 6-hour on-disk
  cache plus a bundled always-works fallback for offline first boot.
- Custom M3U playlists, persisted locally; favourites (★) with per-category
  cursor memory.
- Background stream-health probe — fast / slow / dead dots, fast streams
  sort first.
- Player states: connecting veil with tank progress, error card with
  Retry / Channels / Video-only, auto-hiding info bar (5s, toggleable).
- Every overlay button (Cancel, Retry, …) is reachable via D-pad: ◀ ▶ move,
  ▼ focuses, ▲ unfocuses, OK confirms.

**Remote (web)**
- Sidebar: Remote (D-pad, transport, channel/volume, Info toggle with live
  state), Channels (3-up mosaic, auto-hiding category bar, sticky search),
  Lists (add dialog with clipboard paste, confirm-to-remove), Settings
  (prebuffer seconds, hold-glide repeat rate).
- Shows only your added lists — no built-in rails.

## Quick start

Prerequisites: Flutter SDK (developed on 3.41 / Dart 3.11).

```sh
flutter pub get
flutter run                # desktop / dev device
```

On the Pi (flutter-pi), deploy the release bundle, then open the remote:

```text
http://<pi-ip>:8080/remote
```

The server tries ports 8080–8091 and prints the reachable LAN URLs on boot.
The TV shows its remote URLs on screen as well.

## Remote API

Same-origin JSON + WebSocket (`/ws`):

| Endpoint            | Method | Purpose                                    |
|---------------------|--------|--------------------------------------------|
| `/remote`           | GET    | The remote web app                         |
| `/ws`               | WS     | Live push (`now`, `playlists`) + commands  |
| `/api/now`          | GET    | Playing, transport, volume, info-bar state |
| `/api/key`          | POST   | D-pad / transport key (`{"key":"up"}`)     |
| `/api/play`         | POST   | Play channel by id (`{"id":"…"}`)          |
| `/api/info`         | POST   | Info bar (`{"toggle":true}` / `{"visible"}`)|
| `/api/categories`   | GET    | Your lists only (index, id, title, count)  |
| `/api/channels`     | GET    | Channels (`?category=&q=&limit=`)          |
| `/api/playlists`    | GET/POST/DELETE | Saved M3U lists                |
| `/api/settings`     | GET/POST | `prebufferSecs`, `repeatRate`            |
| `/api/tracks`       | GET/POST | HLS quality variants                     |
| `/health`           | GET    | Port, LAN URLs, channel count              |

## Project layout

```text
lib/
  main.dart                  # boot: player → remote server → catalog → health
  models/                    # TvChannel (+ChannelRail), CustomPlaylist
  services/
    app_state.dart           # single ChangeNotifier: TV + remote truth
    catalog_service.dart     # M3U fetch/parse (isolate), rails, fallback
    player_service.dart      # media_kit wiring, retry, quality
    local_remote_server.dart # HttpServer + WebSocket + remote web UI
    stream_health.dart       # background probe + ranking
    custom_playlist_store.dart
    remote_command.dart      # shared key vocabulary
  ui/
    tv_home.dart             # sidebar + grid home
    player_screen.dart       # player + overlays + info bar
```

## Performance notes (Pi 4)

- Release mode + hardware decode; opacity-only overlay animations.
- Bounded image cache (~120 posters / 32MB); builder-based rails so
  thousand-channel lists cost nothing off-screen.
- Health probes and playlist refreshes run off the boot path; the first
  frame paints before the catalog lands.
