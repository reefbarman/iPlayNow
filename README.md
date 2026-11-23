<p align="center"><img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="iPlayGFN, a GeForce NOW app for iPhone and iPad"></p>

# iPlayGFN: GeForce NOW for iPhone and iPad

iPlayGFN is a free, open-source GeForce NOW player for iPhone and iPad. Sign in, pick a game you own and play it on a GeForce NOW rig, streamed natively with hardware decoding and Metal rather than through a web page. It shares its player, controls and settings with [iPlay5](https://github.com/reefbarman/iPlay5), my PS5 Remote Play app, so it's tuned for the iPhone Duo's near-square inner screen and works on any iPhone or iPad running iOS 17 or later. Install it by sideloading with AltStore, SideStore or Sideloadly.

> [!IMPORTANT]
> **Play with a physical controller or virtual controls.** Auto keeps the virtual controls out of the way when you have a supported controller connected, such as an Xbox controller, DualSense or Backbone. Change this in Settings › Virtual controls.
>
> **Your own games only.** The library shows the games you own on stores you've linked to GeForce NOW (Steam, Epic, Xbox and others). Link stores in GeForce NOW itself, then pull to refresh.

Not affiliated with or endorsed by NVIDIA. "GeForce NOW" is a trademark of NVIDIA Corporation, and "Xbox" is a trademark of Microsoft Corporation.

## Features

The highlights are below. The [changelog](CHANGELOG.md) lists what changed in each release.

- **Native streaming:** GeForce NOW's NVST protocol, hardware H.265/H.264 decoding and Metal drawing at the screen's native resolution. Up to 4K, 120 fps, 100 Mbps and HDR where your membership allows, Fit or Zoom to fill, Sharp or MetalFX upscaling, and a 120 Hz screen on ProMotion iPhones.
- **Per-game video settings:** press and hold a cover, then **Video settings**, to give a game its own resolution, frame rate, bitrate, codec and HDR.
- **Frame generation (experimental):** an in-between frame for each pair the stream sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay.
- **Your library as covers:** a grid of the games you own, tagged RTX and HDR where GeForce NOW supports them, with search, a store filter, and sorting by recently played or A to Z. It opens instantly from the last list, then refreshes. A controller moves around the grid and A plays.
- **Straight into the game:** no tutorials or setup screens. Tap a cover and you're in the queue. Games you own on more than one store ask once which to play, and press and hold changes it later.
- **Controllers and rumble:** Xbox, PlayStation and MFi controllers, with rumble on the controller, or on the phone when the controller has no motors.
- **Gyro aiming:** turn the controller (or the phone) to aim with the right stick, always or only while holding LT or RB, tuned to each game's dead zone.
- **Virtual controls:** an Xbox layout with coloured A, B, X and Y, floating or fixed sticks, three sizes and adjustable opacity, shown only when you don't have a controller.
- **Made for the iPhone Duo:** the game waits on the outer screen until you unfold, plays on the inner one, and folding pauses it.
- **Handy extras:** battery and temperature in the stream menu, a warning when the phone gets hot, and stats along the top of the picture.

## Install

iPlayGFN isn't on the App Store. You install the `.ipa` from [Releases](https://github.com/reefbarman/iPlayGFN/releases) yourself with a sideloading tool, signed with your own Apple ID. A free Apple ID is enough because the app needs no special permissions. Free-account apps expire after 7 days unless they're refreshed, which SideStore and AltStore do in the background.

**SideStore or AltStore (recommended, gets updates):** add this source, then install iPlayGFN from it:

```
https://raw.githubusercontent.com/reefbarman/iPlayGFN/main/altstore-source.json
```

**Sideloadly or another signer:** download `iPlayGFN.ipa` from the latest release and install it as you would any other IPA.

**Developer account:** if you have a paid Apple Developer account, you can build from source (below) and the app lasts a year.

## Using it

1. Open iPlayGFN and choose your GeForce NOW provider (NVIDIA, or a regional partner). Sign in.
2. Tap a game's cover. It queues for a rig if needed, sets up, then streams.
3. While streaming: tap the top-right corner, then the gear, for the menu and settings. Or hold **View + Menu** for a second. Tap the top-left corner, then the Xbox logo, to press the Xbox button (GeForce NOW's in-game menu). Tap the bottom-right corner to turn frame generation on and off.
4. **Quit game** in the menu ends the session on GeForce NOW, so it doesn't keep running on your account.

Resolution, frame rate, bitrate, codec and HDR are in Settings (or per game, from the cover). GeForce NOW fixes them when it sets up the rig, so change them before you start a game; the stream menu shows what the session is using. Everything else (picture, controls, vibration, stats) can be changed mid-game from the stream menu.

## Build from source

Needs a Mac with Xcode 16 or later and Homebrew.

```sh
brew install xcodegen
git clone https://github.com/reefbarman/iPlayGFN.git
cd iPlayGFN
scripts/prepare-frameworks.sh                            # -> Frameworks/OpenSSL and usrsctp xcframeworks
cp Config/Local.xcconfig.example Config/Local.xcconfig  # set your team ID and a bundle ID
xcodegen generate                                       # -> iPlayGFN.xcodeproj
open iPlayGFN.xcodeproj                                 # run on your phone
```

To build the same unsigned IPA the releases use, run `scripts/package-ipa.sh`, which writes `build/iPlayGFN.ipa`. To publish a release, push a `v*` tag. The release workflow builds the IPA, attaches it to a GitHub release and adds it to `altstore-source.json`.

### Layout

| Path             | What                                                                                                      |
| ---------------- | --------------------------------------------------------------------------------------------------------- |
| `NVSTKit/`       | The NVST receiver from OpenNOW (`Sources/NVST`), plus `NVSTStream`, a small Swift API for the app         |
| `App/GFN/`       | Sign-in, library, sessions and the launch queue against the GeForce NOW services                          |
| `App/Streaming/` | Session, Metal renderer and shaders, frame generation, audio, controller input and rumble                 |
| `App/Views/`     | SwiftUI screens                                                                                           |
| `Vendor/`        | Prebuilt OpenSSL and usrsctp from OpenNOW, unpacked into `Frameworks/` by `scripts/prepare-frameworks.sh` |
| `Config/`        | Signing settings. Your team and bundle ID go in the git-ignored `Local.xcconfig`                          |

Files under `NVSTKit/Sources/NVST` are OpenNOW's, and every change made to them here is marked with an `// iPlayGFN:` comment, which keeps updates from upstream easy to review. The upstream commit is in `Licenses/OPENNOW_UPSTREAM_COMMIT`.

## Credits and license

- [OpenNOW](https://github.com/OpenCloudGaming/OpenNOW) (MIT) worked out GeForce NOW's native NVST streaming protocol. iPlayGFN uses its NVST receiver as the streaming backend; sign-in, library, sessions and every screen are iPlayGFN's own. See `Licenses/OpenNOW-MIT.txt` and `Licenses/OpenNOW-THIRD_PARTY_NOTICES.txt`.
- The player, controls and settings come from [iPlay5](https://github.com/reefbarman/iPlay5), which is built on [chiaki-ng](https://github.com/streetpea/chiaki-ng) and the original [Chiaki](https://git.sr.ht/~thestr4ng3r/chiaki).
- Also bundled: [OpenSSL](https://www.openssl.org) (Apache-2.0) and [usrsctp](https://github.com/sctplab/usrsctp) (BSD), as built by OpenNOW.

iPlayGFN is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only), the same as iPlay5. If you distribute a modified build, you must make its source available under the same license.
