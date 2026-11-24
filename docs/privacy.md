# Privacy policy

iPlayNow doesn't collect or share any personal data with its developer. It has no accounts of its own, no analytics, no ads and no tracking, and the developer never receives anything from the app unless you choose to send it.

To let you play, iPlayNow talks to NVIDIA's GeForce NOW services on your behalf, the same way GeForce NOW's own apps do. What NVIDIA does with that is covered by NVIDIA's privacy policy, not this one.

This policy covers iPlayNow however you installed it: by sideloading, from TestFlight or from an app store.

## What stays on your device

- **Sign-in:** your GeForce NOW sign-in tokens and account details, kept in the iOS Keychain. **Settings › Account › Sign out** removes them.
- **Settings:** your settings, per-game video settings, store choices and the bitrates **Auto bitrate** has learned (each Wi-Fi network is remembered by its local address range, not its name).
- **Library:** a copy of your game list, so it opens instantly.
- **Device ID:** a random ID made when the app first runs. GeForce NOW requires one to tell your devices apart, and it isn't linked to your phone's hardware or Apple ID.
- **Screenshots:** saved to your photo library, and only when you take them.

Deleting the app removes everything except screenshots you've saved to Photos. Keychain items can outlast the app on some iOS versions; signing out first removes them.

## Who iPlayNow talks to

- **NVIDIA's sign-in service** (or your regional GeForce NOW partner's): you sign in on their own page. iPlayNow keeps the sign-in tokens so you stay signed in, and never sees your password.
- **GeForce NOW's services:** to load your library and cover art, start and queue sessions, and find a rig. These requests include your sign-in token, the device ID and your settings, such as the resolution you asked for.
- **The GeForce NOW rig:** the game stream, your controller, touch and keyboard input and (if you turn on **Microphone**) your voice go between your device and the rig running your game.
- **GitHub:** only when you tap a link such as **Source code**, **Report a problem on GitHub** or this policy, which open in your browser.

NVIDIA's [privacy policy](https://www.nvidia.com/en-us/about-nvidia/privacy-policy/) covers your GeForce NOW account and sessions. Nothing is sent anywhere else.

## Permissions

- **Local Network:** NVIDIA's sign-in page finishes by sending you back to a local address on your own phone, which the app catches. Nothing else on your network is used.
- **Microphone:** only used while **Microphone** is on in settings, to send your voice to the game for game and party chat.
- **Photos (add only):** to save screenshots you take from the stream menu. iPlayNow can't see your photo library.

## Diagnostics

**Settings › Share diagnostics** creates a plain-text report only when you tap it, and you choose where it goes (for example, attached to a GitHub issue). IP addresses, IDs, sign-in tokens and your account's name and email are removed before you see it. Nothing is sent automatically. See [Help and troubleshooting](troubleshooting.md).

## Children

iPlayNow doesn't knowingly collect data from anyone, including children, because it doesn't collect data at all. GeForce NOW's own age requirements apply to your NVIDIA account.

## Changes and contact

If this policy changes, the updated version will be published on this page, and its history is in the [GitHub repository](https://github.com/reefbarman/iPlayNow/commits/main/docs/privacy.md). For questions, open an [issue on GitHub](https://github.com/reefbarman/iPlayNow/issues).

iPlayNow is not affiliated with or endorsed by NVIDIA.
