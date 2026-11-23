# Changelog

Every iPlayGFN release, written for players. The same notes are on each [GitHub release](https://github.com/reefbarman/iPlayGFN/releases).

## v0.1.0 (2026-11-24)

The first release of iPlayGFN: a native GeForce NOW player for iPhone and iPad. Sign in, tap one of your games and play it on a GeForce NOW rig, streamed with hardware decoding and Metal instead of a web page. It shares its player, controls and settings with iPlay5, so it's tuned for the iPhone Duo and works on any iPhone or iPad running iOS 17 or later.

### New
- **Sign in** with NVIDIA or a regional GeForce NOW partner.
- **Your library as covers:** the games you own on stores you've linked to GeForce NOW, with search, a store filter and sorting by recently played or A to Z. Covers are tagged **RTX** and **HDR** where GeForce NOW supports them. A controller can move around the grid and A plays.
- **Straight into the game:** tap a cover and you're queued, set up and streaming, with the game's artwork while it launches. Games you own on more than one store ask once which store to play from. Press and hold a cover to change it later.
- **Video:** up to 4K, 120 fps, 100 Mbps and HDR where your membership allows, with H.265 or H.264. Set them in Settings, or per game from **Video settings** when you press and hold a cover. The stream menu shows what the session is using, including the resolution actually being streamed.
- **Picture:** Fit or Zoom to fill, Sharp or MetalFX upscaling, 120 Hz on ProMotion iPhones, and experimental frame generation that turns 30 fps into 60 and 60 into 120.
- **Controllers:** Xbox, PlayStation and MFi controllers with rumble (or phone vibration when the controller has none), and gyro aiming with the controller or the phone.
- **Virtual controls:** an Xbox layout with coloured A, B, X and Y, shown only when you don't have a controller connected.
- **Stream screen:** tap the top-right corner for the menu and settings, or hold **View + Menu**. Tap the top-left corner for the Xbox button, which opens GeForce NOW's in-game menu. **Quit game** ends the session on GeForce NOW.
- **iPhone Duo:** the game waits on the outer screen until you unfold, plays on the inner one, and folding pauses it.

### Notes
- Only games you own are listed. Link your stores in GeForce NOW itself, then pull to refresh.
- 4K, HDR and 120 fps need a membership that includes them, and HDR also needs the game to support it. GeForce NOW quietly lowers what you asked for if not.
- Resolution, frame rate, bitrate, codec and HDR are fixed when a game starts, so change them before launching.
- Install with SideStore or AltStore using `https://raw.githubusercontent.com/reefbarman/iPlayGFN/main/altstore-source.json`, or download `iPlayGFN.ipa` and use Sideloadly.
