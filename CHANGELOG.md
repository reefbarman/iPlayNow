# Changelog

Every iPlayNow release, written for players. The same notes are on each [GitHub release](https://github.com/reefbarman/iPlayNow/releases).

## v0.4.1 (2026-11-25)

### New
- **Rumble updates:** a new slider in Settings › Controller › Vibration sets how many vibration changes per second go to a wireless controller, from 10 to Unlimited (default 25). Lower it if the controls freeze during heavy rumble, raise it if vibration feels less detailed.
- **Share diagnostics in the stream menu:** share a report mid-game, right after something goes wrong, from the Help section at the bottom of the stream menu.

### Fixes
- Heavy rumble could make a wireless controller stop responding for a moment while the game carried on. Rumble now sends fewer, smaller updates, so your button presses get through.
- The Share diagnostics share sheet could close as soon as it opened. It now stays open.

## v0.4.0 (2026-11-25)

### New
- **Controller vibration:** choose how strongly your controller rumbles: Light, Medium or Full. It's in Settings › Controller › Vibration, next to Phone haptics, and the Controller Test uses it too. Full is the default, so rumble feels the same as before unless you change it.

### Fixes
- Rumble could keep buzzing faintly after a game stopped it. The controller's motors now always stop when the rumble ends.

## v0.3.0 (2026-11-25)

A big catch-up with iPlay5. You can now use touch as a mouse, type with the iPhone keyboard and talk in party chat. The app reconnects to your game after a dropout and learns the right bitrate for each Wi-Fi network. Settings work with a controller, and there's a 3D Controller Test, screenshots and a new guide site at [reefbarman.github.io/iPlayNow](https://reefbarman.github.io/iPlayNow/).

### New
- **Touch as a mouse:** for launchers, logins and menus that want a pointer. With a controller, tap the picture to click exactly there and drag to drag. With virtual controls showing, the top half of the screen works like a trackpad: drag to move the pointer, tap to click, and tap then drag to hold the button. Press and hold or tap with two fingers to right-click, and drag with two fingers to scroll. Turn it off in Settings › Virtual controls › Touch as mouse.
- **Typing with the iPhone keyboard:** tap the top-left corner of the stream, then the keyboard button, or choose **Type with the keyboard** in the stream menu. Each letter goes to the game as you type, so logins, password fields and chat work. A bar above the keyboard adds Esc, Tab and the arrow keys.
- **Microphone:** talk in game and party chat. Turn it on in Settings › Audio › Microphone. While streaming, tap the top-left corner, then the mic button, to mute, or use the stream menu. A small red mic stays in the corner while you're muted.
- **Reconnects after a dropout:** if the connection drops mid-game, the app gets the same rig back from GeForce NOW, so your game is still where you left it. It tries three times, then offers **Reconnect**.
- **Auto bitrate:** learns the bitrate that works on each Wi-Fi network. After a clean game it tries a little more next time, and after a game that dropped video it uses less. **Forget learned bitrates** clears what it has learned.
- **Check connection:** in the stream menu, under Connection. It watches 20 seconds of the stream, tells you how the connection is doing and can suggest a bitrate for your next game.
- **Screenshots:** choose **Save screenshot to Photos** in the stream menu to save the game picture, without the virtual controls or black bars.
- **Settings with a controller:** Settings, a game's video settings and the in-game menu all work with a controller. Up and down move, left and right change a setting, A toggles or opens it and B goes back. In the library, Menu opens Settings, View changes the sort and LB and RB step through the stores.
- **Controller Test:** in Settings › Controller and the stream menu. A 3D controller shows every button, stick and trigger as GeForce NOW gets it, turns as you turn yours, and tests rumble and haptics. PlayStation controllers get a DualSense with touchpad, lightbar, player light and adaptive trigger tests. Anything else gets an Xbox controller with trigger motor tests. Tap **Recentre** to face the controller front-on and remember how you hold it.
- **PlayStation button names:** with a DualSense or DualShock 4 connected, settings and hints say Cross, Circle, Square, Triangle, L1, R2 and so on. The virtual controls stay Xbox.
- **No controller? Pick how to play:** if a game starts with no controller connected, it waits for one, or you can choose **Use virtual controls** or **Start without controls**.
- **Home as the Xbox button:** on iOS 27, the app offers to open the iOS setting that lets apps use the controller's Home button. Settings › Controller › Home Button Settings opens it any time. Once it's allowed, Home opens GeForce NOW's in-game menu.
- **Controls Guide:** Settings › Controller › Controls Guide explains the controller shortcuts, touch as a mouse, the virtual controls and the hidden corner buttons.
- **Share diagnostics and Report a problem:** Settings › Share diagnostics makes a text report to attach to a GitHub issue, with IP addresses, IDs, sign-in tokens and your account's name and email removed.
- **About:** Settings › About shows the version, the source code, the licences of everything in the app and the privacy policy.
- **Guides:** every feature and setting is now explained at [reefbarman.github.io/iPlayNow](https://reefbarman.github.io/iPlayNow/).

### Notes
- **Auto bitrate is on by default.** The bitrate in Settings is now the starting bitrate for each Wi-Fi network. Turn **Auto bitrate** off to use a fixed bitrate. On mobile data, and for games with their own video settings, the bitrate is used as set.
- **Microphone is off by default.** iOS asks for microphone access the first time you turn it on, and Photos access the first time you save a screenshot (add only).

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

