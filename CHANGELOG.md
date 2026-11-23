# Changelog

Every iPlayNow release, written for players. The same notes are on each [GitHub release](https://github.com/reefbarman/iPlayNow/releases).

## v0.2.0 (2026-11-24)

iPlayGFN is now **iPlayNow**. Same app, new name. This release also adds controller button hints to the library, and frame generation now kicks in whenever the game itself runs at half your screen's refresh rate.

### New
- **Controller button hints:** a bar along the bottom of the library shows what each button does for the selected cover. A plays, Y opens its **Video settings**, and X chooses the store when you own the game on more than one.
- **Video settings and store choice with a controller:** up and down move, left and right change a value, A toggles and B closes. Without a controller, press and hold a cover as before.
- **Smarter frame generation:** it now follows the game's actual frame rate rather than the stream's. A 60 fps game in a 120 fps stream now gets frame generation on a 120 Hz screen. It waits two seconds before turning on or off, so a game hovering around 60 fps doesn't flicker between the two. When it's on in Settings but not running, the stream stats say why.

### Notes
- **iPlayGFN is now iPlayNow.** iOS treats it as a new app, so it won't update the old one. Install iPlayNow fresh, sign in again and set your settings again, then delete iPlayGFN.
- SideStore and AltStore users: the source URL is now `https://raw.githubusercontent.com/reefbarman/iPlayNow/main/altstore-source.json`. The old URL redirects, but re-adding the source with the new one is the safest option.

## v0.1.0 (2026-11-24)

Released as iPlayGFN, before the app was renamed. This release is no longer available to download. Install the latest iPlayNow release instead.

The first release: a native GeForce NOW player for iPhone and iPad. Sign in, tap one of your games and play it on a GeForce NOW rig, streamed with hardware decoding and Metal instead of a web page. It shares its player, controls and settings with iPlay5, so it's tuned for the iPhone Duo and works on any iPhone or iPad running iOS 17 or later.

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

