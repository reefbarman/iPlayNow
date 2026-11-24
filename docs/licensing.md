# Licences and source code

iPlayNow is free and open source under the [GNU Affero General Public License v3.0](https://github.com/reefbarman/iPlayNow/blob/main/LICENSE) (AGPL-3.0-only).

## What that means for you

- You can use iPlayNow for free, read its source, change it and share it.
- If you distribute a modified build, you must make its source available under the same licence.

## Settings › About

- **Version:** the app's version and build number.
- **Source code:** opens the exact source the build came from (the release tag, or `main` for builds made from source).
- **Licences:** the licence text of iPlayNow and everything bundled into it.
- **Privacy policy:** opens the [privacy policy](privacy.md).

## Getting the source for a version

Every release is tagged in the [GitHub repository](https://github.com/reefbarman/iPlayNow), and **Source code** in Settings › About links to the tag your build came from. The [README](https://github.com/reefbarman/iPlayNow#build-from-source) explains how to build it.

## Bundled components

- **[OpenNOW](https://github.com/OpenCloudGaming/OpenNOW)** (MIT): worked out GeForce NOW's native streaming protocol. iPlayNow uses its stream receiver; sign-in, library, sessions and every screen are iPlayNow's own.
- **[OpenSSL](https://www.openssl.org)** (Apache-2.0) and **[usrsctp](https://github.com/sctplab/usrsctp)** (BSD), as built by OpenNOW.

The player, controls and settings come from [iPlay5](https://github.com/reefbarman/iPlay5), which is also AGPL-3.0.

iPlayNow is not affiliated with or endorsed by NVIDIA. "GeForce NOW" is a trademark of NVIDIA Corporation.
