import Foundation
import Observation

/// A PlayStation that has been registered (linked) with this phone.
struct Console: Codable, Identifiable, Hashable {
	var id = UUID()
	var name: String
	var host: String
	var ps5: Bool
	/// rp_regist_key: 16 bytes (ASCII hex, zero padded)
	var registKey: Data
	/// rp_key ("morning"): 16 bytes
	var rpKey: Data
	var mac: Data
	/// This console's own video and network settings, nil to use the shared ones
	/// (e.g. one PS5 on Ethernet, another on Wi-Fi)
	var customSettings: ConnectionSettings?
	/// Public IP or hostname to use when the console isn't answering on the
	/// local network, e.g. a router with the Remote Play ports forwarded.
	/// Discovery never touches this, unlike `host`.
	var remoteHost: String?
}

extension Console {
	/// The remote address without stray whitespace, nil when unset
	var remoteAddress: String? {
		let trimmed = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return trimmed.isEmpty ? nil : trimmed
	}

	/// This console set up to dial its remote address instead of the LAN one
	func dialing(remote: Bool) -> Console {
		guard remote, let remoteAddress else { return self }
		var copy = self
		copy.host = remoteAddress
		return copy
	}
}

@Observable
final class ConsoleStore {
	private(set) var consoles: [Console] = []

	@ObservationIgnored private let url: URL = {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("consoles.json")
	}()

	init() {
		if let data = try? Data(contentsOf: url),
			let decoded = try? JSONDecoder().decode([Console].self, from: data)
		{
			consoles = decoded
		}
	}

	func add(_ console: Console) {
		// Re-registering the same console replaces the old keys
		consoles.removeAll { $0.mac == console.mac && !console.mac.isEmpty }
		consoles.append(console)
		save()
	}

	func update(_ console: Console) {
		guard let index = consoles.firstIndex(where: { $0.id == console.id }) else { return }
		consoles[index] = console
		save()
	}

	func remove(_ console: Console) {
		consoles.removeAll { $0.id == console.id }
		save()
	}

	private func save() {
		do {
			let data = try JSONEncoder().encode(consoles)
			try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		} catch {
			log.error("Saving consoles failed: \(error.localizedDescription, privacy: .public)")
		}
	}
}

// MARK: - Stream settings

enum StreamResolution: Int, Codable, CaseIterable, Identifiable {
	case p720 = 720
	case p1080 = 1080

	var id: Int { rawValue }
	var label: String { "\(rawValue)p" }
	var size: (width: UInt32, height: UInt32) {
		switch self {
		case .p720: (1280, 720)
		case .p1080: (1920, 1080)
		}
	}
}

enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable {
	case h265
	case h264

	var id: String { rawValue }
	var label: String { self == .h265 ? "H.265 (HEVC)" : "H.264" }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
	/// Whole picture visible, black bars where the screen isn't 16:9
	case fit
	/// Fill the screen, cropping whatever overflows
	case zoom

	var id: String { rawValue }
	var label: String { self == .fit ? "Fit" : "Zoom to fill" }
}


enum VirtualControlsMode: String, Codable, CaseIterable, Identifiable {
	case auto, always, never

	var id: Self { self }
	var label: String {
		switch self {
		case .auto: "Auto"
		case .always: "Always show"
		case .never: "Never show"
		}
	}
}

enum UpscalingMode: String, Codable, CaseIterable, Identifiable {
	case bilinear, sharp, metalFX, metalFX4K

	var id: Self { self }
	var label: String {
		switch self {
		case .bilinear: "Bilinear"
		case .sharp: "Sharp"
		case .metalFX: "MetalFX Spatial"
		case .metalFX4K: "MetalFX 4K"
		}
	}
	var usesMetalFX: Bool { self == .metalFX || self == .metalFX4K }
}

/// Rumble, haptics and trigger effects played on the phone itself, when there's
/// no controller or the controller has no motors
enum PhoneHaptics: String, Codable, CaseIterable, Identifiable {
	case off, light, full

	var id: Self { self }
	var label: String {
		switch self {
		case .off: "Off"
		case .light: "Light"
		case .full: "Full"
		}
	}
	var scale: Float {
		switch self {
		case .off: 0
		case .light: 0.45
		case .full: 1
		}
	}
}

/// Gyro aiming: turn the controller (or the phone) to move the right stick
enum GyroAimMode: String, Codable, CaseIterable, Identifiable {
	case off, always, holdingL2, holdingR1

	var id: Self { self }
	var label: String {
		switch self {
		case .off: "Off"
		case .always: "Always"
		case .holdingL2: "While holding L2"
		case .holdingR1: "While holding R1"
		}
	}
}

/// What looks left and right with gyro aiming
enum GyroAimTurning: String, Codable, CaseIterable, Identifiable {
	/// Steam Input's "local space"
	case turnAndTilt, turn, tilt

	var id: Self { self }
	var label: String {
		switch self {
		case .turnAndTilt: "Turn and tilt"
		case .turn: "Turn"
		case .tilt: "Tilt"
		}
	}
	var usesYaw: Bool { self != .tilt }
	var usesRoll: Bool { self != .turn }
}

enum ControlsSize: String, Codable, CaseIterable, Identifiable {
	case small, medium, large

	var id: Self { self }
	var label: String {
		switch self {
		case .small: "Small"
		case .medium: "Medium"
		case .large: "Large"
		}
	}
	var scale: CGFloat {
		switch self {
		case .small: 0.85
		case .medium: 1
		case .large: 1.15
		}
	}
}

enum StatsMode: String, Codable, CaseIterable, Identifiable {
	case off
	/// One line: resolution, fps, bitrate, ping, loss
	case simple
	/// Everything, laid out across the black bar
	case advanced

	var id: Self { self }
	var label: String {
		switch self {
		case .off: "Off"
		case .simple: "Simple"
		case .advanced: "Advanced"
		}
	}
}

struct StreamSettings: Codable, Equatable {
	var resolution: StreamResolution = .p1080
	var fps: Int = 60
	var bitrateMbps: Int = 30
	/// Learn the bitrate that works for each console on each network (BitrateMemory).
	/// `bitrateMbps` is then where a new network starts.
	var autoBitrate: Bool = true
	var codec: VideoCodecChoice = .h265
	var hdr: Bool = false
	var displayMode: DisplayMode = .fit
	var upscaling: UpscalingMode = .sharp
	var statsMode: StatsMode = .off
	/// Phone gyro for virtual controls and controllers without motion sensors (e.g. Backbone)
	var phoneMotion: Bool = true
	/// Gyro moves the right stick instead of going to the game as motion
	var gyroAim: GyroAimMode = .off
	/// Multiplies how far the right stick moves for a given turn speed, 0.25...3
	var gyroAimSensitivity: Double = 1
	var gyroAimInvertY: Bool = false
	var gyroAimTurning: GyroAimTurning = .turnAndTilt
	/// Up/down speed relative to left/right, 0.5...3
	var gyroAimVerticalScale: Double = 1.5
	/// The game's own stick dead zone, which gyro movement starts past, 0...0.4
	var gyroAimDeadzone: Double = 0.15
	/// The game's stick response curve power, undone for gyro, 1...3 (1 is linear)
	var gyroAimResponseCurve: Double = 1.5
	/// Push left/right and up/down past the game's dead zone separately
	var gyroAimPerAxisDeadzone: Bool = false
	/// Master switch for rumble, haptics and trigger motors
	var rumble: Bool = true
	/// How strongly rumble plays on the phone (virtual controls, or a controller without motors)
	var phoneHaptics: PhoneHaptics = .full
	/// Send the phone's mic to the console for game and party chat
	var microphone: Bool = false
	/// Use the controller's Select/View button as the DualSense touchpad click
	var selectIsTouchpad: Bool = false
	var virtualControls: VirtualControlsMode = .auto
	var controlsSize: ControlsSize = .medium
	/// 0.2...1, multiplies the virtual controls' own transparency
	var controlsOpacity: Double = 1
	/// Sticks stay put in their own spots instead of starting wherever a thumb lands
	var fixedSticks: Bool = false
	/// Keep a ProMotion screen at 120 Hz while streaming, so frames wait less for the next refresh
	var highRefreshDisplay: Bool = true
	/// Experimental: make an in-between frame for each pair of real ones (FrameGen.metal)
	var frameGeneration: Bool = false
	/// Debug: a button on the stream that saves the last few seconds of frames
	var frameCapture: Bool = false
	/// Experimental: offer the PS5 the newer Takion v20 stream protocol. The console picks;
	/// it stays on v12 if it doesn't answer. Off keeps the stock chiaki-ng v12 path.
	var takionV20: Bool = false
	/// Optional: ride out network hitches at the cost of a little delay while they happen.
	/// Waits longer for late video packets, keeps the picture moving (briefly smeared)
	/// instead of freezing after a lost frame, and holds back a frame or two to even out
	/// uneven arrival (FramePacer). ChiakiKit/patches/0002-network-smoothing.patch.
	var networkSmoothing: Bool = false

	/// HDR needs HEVC
	var effectiveCodec: VideoCodecChoice { hdr ? .h265 : codec }

	/// The video and network part, which a console can override
	var connection: ConnectionSettings {
		get {
			ConnectionSettings(
				resolution: resolution, fps: fps, bitrateMbps: bitrateMbps, codec: codec, hdr: hdr,
				networkSmoothing: networkSmoothing, takionV20: takionV20)
		}
		set {
			resolution = newValue.resolution
			fps = newValue.fps
			bitrateMbps = newValue.bitrateMbps
			codec = newValue.codec
			hdr = newValue.hdr
			networkSmoothing = newValue.networkSmoothing
			takionV20 = newValue.takionV20
		}
	}

	/// These settings with a console's own video and network settings on top
	func applying(_ custom: ConnectionSettings?) -> StreamSettings {
		guard let custom else { return self }
		var settings = self
		settings.connection = custom
		return settings
	}

	init() {}

	private enum LegacyKeys: String, CodingKey { case frameGenMode, sharpUpscaling, showStats }

	/// Missing keys keep their defaults, so adding a setting doesn't reset the others
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = StreamSettings()
		resolution = try c.decodeIfPresent(StreamResolution.self, forKey: .resolution) ?? d.resolution
		fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
		bitrateMbps = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps
		autoBitrate = try c.decodeIfPresent(Bool.self, forKey: .autoBitrate) ?? d.autoBitrate
		codec = try c.decodeIfPresent(VideoCodecChoice.self, forKey: .codec) ?? d.codec
		hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
		displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? d.displayMode
		let legacy = try decoder.container(keyedBy: LegacyKeys.self)
		if let mode = try? c.decodeIfPresent(UpscalingMode.self, forKey: .upscaling) {
			upscaling = mode
		} else if let sharp = try? legacy.decodeIfPresent(Bool.self, forKey: .sharpUpscaling) {
			upscaling = sharp ? .sharp : .bilinear
		}
		if let mode = try? c.decodeIfPresent(StatsMode.self, forKey: .statsMode) {
			statsMode = mode
		} else if let show = try? legacy.decodeIfPresent(Bool.self, forKey: .showStats) {
			// The old on/off toggle showed everything
			statsMode = show ? .advanced : .off
		}
		phoneMotion = try c.decodeIfPresent(Bool.self, forKey: .phoneMotion) ?? d.phoneMotion
		gyroAim = (try? c.decodeIfPresent(GyroAimMode.self, forKey: .gyroAim)) ?? d.gyroAim
		gyroAimSensitivity = min(3, max(0.25, try c.decodeIfPresent(Double.self, forKey: .gyroAimSensitivity) ?? d.gyroAimSensitivity))
		gyroAimInvertY = try c.decodeIfPresent(Bool.self, forKey: .gyroAimInvertY) ?? d.gyroAimInvertY
		gyroAimTurning = (try? c.decodeIfPresent(GyroAimTurning.self, forKey: .gyroAimTurning)) ?? d.gyroAimTurning
		gyroAimVerticalScale = min(3, max(0.5, try c.decodeIfPresent(Double.self, forKey: .gyroAimVerticalScale) ?? d.gyroAimVerticalScale))
		gyroAimDeadzone = min(0.4, max(0, try c.decodeIfPresent(Double.self, forKey: .gyroAimDeadzone) ?? d.gyroAimDeadzone))
		gyroAimResponseCurve = min(3, max(1, try c.decodeIfPresent(Double.self, forKey: .gyroAimResponseCurve) ?? d.gyroAimResponseCurve))
		gyroAimPerAxisDeadzone = try c.decodeIfPresent(Bool.self, forKey: .gyroAimPerAxisDeadzone) ?? d.gyroAimPerAxisDeadzone
		rumble = try c.decodeIfPresent(Bool.self, forKey: .rumble) ?? d.rumble
		phoneHaptics = (try? c.decodeIfPresent(PhoneHaptics.self, forKey: .phoneHaptics)) ?? d.phoneHaptics
		microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? d.microphone
		selectIsTouchpad = try c.decodeIfPresent(Bool.self, forKey: .selectIsTouchpad) ?? d.selectIsTouchpad
		virtualControls = (try? c.decodeIfPresent(VirtualControlsMode.self, forKey: .virtualControls)) ?? d.virtualControls
		controlsSize = (try? c.decodeIfPresent(ControlsSize.self, forKey: .controlsSize)) ?? d.controlsSize
		controlsOpacity = min(1, max(0.2, try c.decodeIfPresent(Double.self, forKey: .controlsOpacity) ?? d.controlsOpacity))
		fixedSticks = try c.decodeIfPresent(Bool.self, forKey: .fixedSticks) ?? d.fixedSticks
		highRefreshDisplay = try c.decodeIfPresent(Bool.self, forKey: .highRefreshDisplay) ?? d.highRefreshDisplay
		if let on = try c.decodeIfPresent(Bool.self, forKey: .frameGeneration) {
			frameGeneration = on
		} else if let mode = try? legacy.decodeIfPresent(String.self, forKey: .frameGenMode) {
			frameGeneration = mode != "off"
		}
		frameCapture = try c.decodeIfPresent(Bool.self, forKey: .frameCapture) ?? d.frameCapture
		takionV20 = try c.decodeIfPresent(Bool.self, forKey: .takionV20) ?? d.takionV20
		networkSmoothing = try c.decodeIfPresent(Bool.self, forKey: .networkSmoothing) ?? d.networkSmoothing
	}
}

/// The settings that depend on the network path to a console. Changing any of them reconnects.
struct ConnectionSettings: Codable, Hashable {
	var resolution: StreamResolution
	var fps: Int
	var bitrateMbps: Int
	var codec: VideoCodecChoice
	var hdr: Bool
	var networkSmoothing: Bool
	var takionV20: Bool
}

@Observable
final class SettingsStore {
	var settings: StreamSettings {
		didSet { save() }
	}

	@ObservationIgnored private let key = "streamSettings"

	init() {
		if let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data)
		{
			settings = decoded
		} else {
			settings = StreamSettings()
		}
	}

	private func save() {
		if let data = try? JSONEncoder().encode(settings) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}
}
