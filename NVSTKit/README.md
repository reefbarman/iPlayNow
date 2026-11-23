# NVSTKit

iPlayGFN's streaming backend: a receiver for NVIDIA's native NVST protocol (RTSPS negotiation, SRTP video, DTLS/SCTP control, input and Opus audio), packaged as a static framework the way ChiakiKit is for iPlay5.

## What's in here

- `Sources/NVST/`: the NVST receiver from [OpenNOW](https://github.com/OpenCloudGaming/OpenNOW) iOS at upstream commit `9ce50090f08b83e3695dba6e6f74d58688562383` (`ios/OpenNOWiOS/OpenNOWiOS/NVST`). OpenNOW ported it from OpenNOW-Mac (revision in `Sources/NVST/UPSTREAM.json`). MIT; licences for it and its dependencies (OpenSSL Apache 2.0, usrsctp BSD) are in `Sources/NVST/Licenses`.
- `Sources/NVSTStream.swift`: iPlayGFN's adapter and the module's intended API (`NVSTStream`, `NVSTStreamConfig`, `NVSTGamepad`, `NVSTEnd`, `NVSTStats`). It's a fork of OpenNOW's `NativeStreamNVST.swift` glue with the WebRTC, app settings and diagnostics coupling removed: frames go straight out as `CVPixelBuffer`s, audio is pulled into a ring buffer the app reads on its render thread, and gamepad state is sent as `NvstGamepadPacket`s.
- `Sources/NativeStreamTenBitSurface.swift`: a small helper the decoder needs, copied from OpenNOW's `NativeStreamHDRMetal.swift`.

OpenSSL and usrsctp come from `Vendor/OpenNOW-iOS-128-native-libraries.zip`, extracted into `Frameworks/` by `scripts/prepare-frameworks.sh`.

## Local modifications to upstream files

Every edit is marked with an `// iPlayGFN:` comment.

- `Native/NvstNativeBundle.swift`: `startAudioDevice()` returns early when the bundle is created with `startsAudioDevice: false`, so `close()` doesn't deactivate the app's `AVAudioSession`.

The upstream files still declare their types `public`; the app should only use the API in `NVSTStream.swift`.
