# Help and troubleshooting

## Reporting a problem

Right after the problem happens, without closing the app, open **Settings › Share diagnostics** and attach the file to a [GitHub issue](https://github.com/reefbarman/iPlayNow/issues/new). It's also at the bottom of the stream menu, so you can share it mid-game. **Report a problem on GitHub** in the same section opens a new issue.

The report is plain text, so you can check it before sending. It has the app version, your phone model, screen details, settings and the app's logs since it was opened. IP addresses, IDs, sign-in tokens and your account's name and email are removed.

## The controller stops responding during heavy rumble

A wireless controller's vibration and your button presses share one Bluetooth connection. If the controls freeze for a moment while the controller rumbles hard, lower **Settings › Controller › Vibration › Rumble updates**. Diagnostics note when the controller went quiet, which helps if you report it.

## The library is empty or missing games

The library only shows games you own on stores you've linked to GeForce NOW. Link stores in GeForce NOW itself (for example on play.geforcenow.com), then pull to refresh in iPlayNow.

## Controller problems

Open **Settings › Controller › Controller Test** to see exactly what GeForce NOW gets from your controller and to try its rumble. See [Controller Test](controllers.md#controller-test).

On iOS 27, if the Home button opens the Game Overlay instead of GeForce NOW's menu, see [The Xbox button and the Home button](controllers.md#the-xbox-button-and-the-home-button).

## Stutter or lost video

- Turn on **Stats** (Settings › Display) to see bitrate, ping and loss.
- Run **Check connection** from the stream menu while playing something busy.
- Lower the bitrate, or leave **Auto bitrate** on so it learns what works.
- Use 5 GHz or 6 GHz Wi-Fi.

See [Connection](connection.md) for details.

## Known limitations

- **Your membership sets the limits.** 1440p, 4K, 120 fps and HDR need GeForce NOW Ultimate.
- **Video settings are fixed per session.** GeForce NOW sets them when the rig starts, so change them before you play.
- **One controller.** Local co-op with several controllers isn't supported.
- **Not on the App Store.** Free Apple ID installs need refreshing every 7 days, which SideStore and AltStore do in the background.
