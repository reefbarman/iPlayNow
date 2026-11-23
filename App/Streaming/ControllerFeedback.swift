import ChiakiKit
import CoreHaptics
import GameController
import QuartzCore

/// A PS5 adaptive trigger effect.
///
/// The console sends the DualSense's own effect block: a type byte and 10
/// parameter bytes. This decodes the known effect types into the shapes
/// GameController can express. The trigger's travel is split into 10 zones.
struct TriggerEffect: Equatable {
	enum Kind: Equatable {
		case off
		/// Resistance per zone, 0...1
		case feedback(zones: [Float])
		/// Resistance between two positions (0...1) that gives way at the end, like a gun trigger
		case weapon(start: Float, end: Float, strength: Float)
		/// Vibration per zone, 0...1, felt while the trigger is in that zone
		case vibration(zones: [Float], hz: Float)
	}

	static let off = TriggerEffect(kind: .off)
	let kind: Kind

	init(kind: Kind) { self.kind = kind }

	init(type: UInt8, data d: [UInt8]) {
		self.kind = d.count >= 10 ? Self.decode(type: type, d) : .off
	}

	private static func decode(type: UInt8, _ d: [UInt8]) -> Kind {
		let mask = Int(d[0]) | Int(d[1]) << 8
		let active = (0..<10).filter { mask & (1 << $0) != 0 }
		/// Three bits per active zone; the stored value is level - 1 (levels 1...8)
		func levels() -> [Float] {
			let packed = UInt32(d[2]) | UInt32(d[3]) << 8 | UInt32(d[4]) << 16 | UInt32(d[5]) << 24
			return (0..<10).map { zone in
				mask & (1 << zone) != 0 ? Float(((packed >> (3 * UInt32(zone))) & 0x7) + 1) / 8 : 0
			}
		}
		func range(_ from: Int, _ to: Int, _ value: Float) -> [Float] {
			(0..<10).map { $0 >= from && $0 <= to ? value : 0 }
		}
		/// Position byte (0...255) to a zone
		func zone(_ byte: UInt8) -> Int { min(9, Int(byte) * 10 / 256) }
		let first = active.first
		let last = active.last

		switch type {
		case 0x21:  // feedback: resistance per zone
			return active.isEmpty ? .off : .feedback(zones: levels())
		case 0x25:  // weapon: start and end zone bits, strength
			guard let first, let last, first < last else { return .off }
			return .weapon(start: Float(first) / 9, end: Float(last) / 9, strength: Float((d[2] & 0x7) + 1) / 8)
		case 0x22:  // bow: resistance that snaps back at the end; feels closest to weapon
			guard let first, let last, first < last else { return .off }
			return .weapon(start: Float(first) / 9, end: Float(last) / 9, strength: Float((d[2] & 0x7) + 1) / 8)
		case 0x26:  // vibration: amplitude per zone, frequency in Hz
			return active.isEmpty || d[8] == 0 ? .off : .vibration(zones: levels(), hz: Float(d[8]))
		case 0x23:  // galloping: rhythmic taps between two zones
			guard let first, let last, d[3] > 0 else { return .off }
			return .vibration(zones: range(first, last, 0.6), hz: Float(d[3]))
		case 0x27:  // machine: vibration alternating between two amplitudes
			guard let first, let last, d[3] > 0 else { return .off }
			let amplitude = Float(max(d[2] & 0x7, (d[2] >> 3) & 0x7)) / 7
			return amplitude > 0 ? .vibration(zones: range(first, last, amplitude), hz: Float(d[3])) : .off
		case 0x01:  // simple feedback: start position, strength (0...255)
			return d[1] == 0 ? .off : .feedback(zones: range(zone(d[0]), 9, Float(d[1]) / 255))
		case 0x02:  // simple weapon: start, end, strength (0...255)
			guard d[2] > 0, d[0] < d[1] else { return .off }
			return .weapon(start: Float(d[0]) / 255, end: Float(d[1]) / 255, strength: Float(d[2]) / 255)
		case 0x06:  // simple vibration: frequency, amplitude, start position
			guard d[0] > 0, d[1] > 0 else { return .off }
			return .vibration(zones: range(zone(d[2]), 9, Float(d[1]) / 255), hz: Float(d[0]))
		case 0x11:  // limited feedback: start position, strength (0...10)
			return d[1] == 0 ? .off : .feedback(zones: range(min(9, Int(d[0])), 9, min(1, Float(d[1]) / 10)))
		case 0x12:  // limited weapon: start, end (0...255), strength (0...10)
			guard d[2] > 0, d[0] < d[1] else { return .off }
			return .weapon(start: Float(d[0]) / 255, end: Float(d[1]) / 255, strength: min(1, Float(d[2]) / 10))
		default:  // 0x05 is "off"; anything unknown is treated the same
			return .off
		}
	}
}

/// Everything the console sends back to the controller: rumble, DualSense
/// haptics, adaptive triggers, lightbar colour and player LEDs.
///
/// - DualSense: haptics and rumble through its actuators, adaptive triggers
///   per zone, lightbar and player LEDs.
/// - Controllers with trigger motors (Xbox): rumble, plus trigger vibration
///   effects and the "click" of a weapon or resistance effect on the trigger motors.
/// - DualShock 4: rumble and lightbar. Anything else with haptics: rumble.
/// - No controller (on-screen controls), or one without motors (e.g. a clamp
///   like the Backbone): rumble, haptics and trigger effects on the phone itself.
///
/// Call from the main thread unless noted.
final class ControllerFeedback {
	/// The Rumble setting: rumble, haptics and trigger motors
	var rumbleEnabled = true {
		didSet {
			let enabled = rumbleEnabled
			queue.async { self.motorsEnabled = enabled; if !enabled { self.silence() } }
		}
	}

	/// The Phone haptics setting: how strongly the phone plays it all, 0...1
	var phoneHapticsScale: Float = 1 {
		didSet {
			let scale = phoneHapticsScale
			queue.async { self.phoneScale = scale; self.flushPhone() }
		}
	}

	private let queue = DispatchQueue(label: "iPlay5.controller-feedback", qos: .userInteractive)

	// Main thread
	private var controller: GCController?
	private var effects: [TriggerEffect] = [.off, .off]
	private var triggerScale: Float = 1
	private var lightbar: (UInt8, UInt8, UInt8)?
	private var playerNumber = 0
	private var savedLight: GCColor?
	private var savedPlayerIndex = GCControllerPlayerIndex.indexUnset
	/// Trigger effects are played on motors (trigger motors or the phone)
	private var emulatesTriggers = false

	// Feedback queue
	private var handles: [Motor] = []
	private var triggerMotors: [Motor] = []
	/// The phone's own haptics, when the controller has none
	private var phone: Motor?
	/// What rumble/haptics and trigger effects want, per side (level, sharpness); the phone plays the strongest
	private var rumbleOut: [(Float, Float)] = [(0, 0.5), (0, 0.5)]
	private var triggerOut: [(Float, Float)] = [(0, 0.5), (0, 0.5)]
	private var screenTriggers: [Float] = [0, 0]
	private var motorsEnabled = true
	private var phoneScale: Float = 1
	private var hapticScale: Float = 1
	private var motorEffects: [TriggerEffect] = [.off, .off]
	private var motorTriggerScale: Float = 1
	private var triggerValues: [Float] = [0, 0]
	private var armed = [true, true]
	private var hapticsSharpness: [Float] = [0.5, 0.5]
	private var lastHaptics: CFTimeInterval = 0
	private var watchdog: DispatchSourceTimer?

	// MARK: - Controller

	func attach(_ controller: GCController?) {
		detach()
		self.controller = controller
		if let controller {
			savedLight = controller.light?.color
			savedPlayerIndex = controller.playerIndex
			applyLightbar()
			applyPlayerNumber()
		}

		let isDualSense = controller?.extendedGamepad is GCDualSenseGamepad
		let haptics = controller?.haptics
		let localities = haptics?.supportedLocalities ?? []
		let wantTriggers = !isDualSense && localities.contains(.leftTrigger) && localities.contains(.rightTrigger)
		let (summary, emulates): (String, Bool) = queue.sync {
			if let haptics {
				if localities.contains(.leftHandle) && localities.contains(.rightHandle) {
					handles = [.leftHandle, .rightHandle].compactMap { Motor(haptics: haptics, locality: $0, queue: queue) }
				}
				if handles.count != 2 {
					handles = [Motor(haptics: haptics, locality: .default, queue: queue)].compactMap { $0 }
				}
				if wantTriggers {
					let motors = [GCHapticsLocality.leftTrigger, .rightTrigger].compactMap { Motor(haptics: haptics, locality: $0, queue: queue) }
					triggerMotors = motors.count == 2 ? motors : []
				}
			}
			if handles.isEmpty { phone = Motor.phone(queue: queue) }
			startWatchdog()
			let summary = "\(handles.count) rumble motor(s), \(triggerMotors.count) trigger motor(s), phone haptics \(phone != nil ? "yes" : "no"), controller haptics [\(localities.map(\.rawValue).sorted().joined(separator: ", "))]"
			return (summary, triggerMotors.count == 2 || phone != nil)
		}
		emulatesTriggers = emulates
		applyTriggerEffects()
		log.notice("Feedback: \(summary, privacy: .public), adaptive triggers \(isDualSense ? "yes" : "no", privacy: .public), light \(controller?.light != nil ? "yes" : "no", privacy: .public)")
	}

	/// Puts the controller back the way we found it
	func detach() {
		if let controller {
			if let ds = controller.extendedGamepad as? GCDualSenseGamepad {
				ds.leftTrigger.setModeOff()
				ds.rightTrigger.setModeOff()
			}
			if let light = controller.light, let savedLight { light.color = savedLight }
			controller.playerIndex = savedPlayerIndex
		}
		controller = nil
		savedLight = nil
		emulatesTriggers = false
		queue.sync {
			watchdog?.cancel()
			watchdog = nil
			(handles + triggerMotors + [phone].compactMap { $0 }).forEach { $0.stop() }
			handles = []
			triggerMotors = []
			phone = nil
			triggerValues = [0, 0]
			rumbleOut = [(0, 0.5), (0, 0.5)]
			triggerOut = [(0, 0.5), (0, 0.5)]
			armed = [true, true]
		}
	}

	/// Forgets what the last session asked for
	func reset() {
		effects = [.off, .off]
		triggerScale = 1
		lightbar = nil
		playerNumber = 0
		queue.async {
			self.hapticScale = 1
			self.motorEffects = [.off, .off]
			self.motorTriggerScale = 1
		}
	}

	// MARK: - Console requests

	/// Lightbar, player LEDs and the console's intensity settings
	func padInfo(_ type: CKPadInfoType, _ a: UInt8, _ b: UInt8, _ c: UInt8) {
		switch type {
		case CK_PAD_INFO_LIGHTBAR:
			lightbar = (a, b, c)
			applyLightbar()
		case CK_PAD_INFO_PLAYER:
			playerNumber = Int(a & 0xf)
			applyPlayerNumber()
		case CK_PAD_INFO_HAPTIC_INTENSITY:
			let scale = Self.scale(a)
			log.notice("Console vibration intensity: \(scale, privacy: .public)")
			queue.async { self.hapticScale = scale; if scale == 0 { self.silence() } }
		case CK_PAD_INFO_TRIGGER_INTENSITY:
			triggerScale = Self.scale(a)
			log.notice("Console trigger effect intensity: \(self.triggerScale, privacy: .public)")
			applyTriggerEffects()
		default:
			break
		}
	}

	/// Matches chiaki-ng's multipliers for the console's Weak/Medium/Strong settings
	private static func scale(_ intensity: UInt8) -> Float {
		switch CKIntensity(rawValue: UInt32(intensity)) {
		case CK_INTENSITY_OFF: return 0
		case CK_INTENSITY_WEAK: return 0.33
		case CK_INTENSITY_MEDIUM: return 0.5
		default: return 1
		}
	}

	func setTriggerEffects(left: TriggerEffect, right: TriggerEffect) {
		guard effects != [left, right] else { return }
		effects = [left, right]
		applyTriggerEffects()
	}

	private func applyLightbar() {
		guard let light = controller?.light, let (r, g, b) = lightbar else { return }
		light.color = GCColor(red: Float(r) / 255, green: Float(g) / 255, blue: Float(b) / 255)
	}

	private func applyPlayerNumber() {
		guard let controller, (1...4).contains(playerNumber) else { return }
		controller.playerIndex = GCControllerPlayerIndex(rawValue: playerNumber - 1) ?? .indexUnset
	}

	private func applyTriggerEffects() {
		let effects = effects
		let scale = triggerScale
		if let ds = controller?.extendedGamepad as? GCDualSenseGamepad {
			Self.apply(effects[0], scale: scale, to: ds.leftTrigger)
			Self.apply(effects[1], scale: scale, to: ds.rightTrigger)
		}
		guard emulatesTriggers else { return }
		queue.async {
			self.motorEffects = effects
			self.motorTriggerScale = scale
			self.armed = [true, true]
			self.updateTriggerMotors()
		}
	}

	private static func apply(_ effect: TriggerEffect, scale: Float, to trigger: GCDualSenseAdaptiveTrigger) {
		guard scale > 0 else { return trigger.setModeOff() }
		switch effect.kind {
		case .off:
			trigger.setModeOff()
		case .feedback(let zones):
			trigger.setModeFeedback(resistiveStrengths: .init(values: tuple(zones.map { $0 * scale })))
		case .weapon(let start, let end, let strength):
			trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength * scale)
		case .vibration(let zones, let hz):
			trigger.setModeVibration(amplitudes: .init(values: tuple(zones.map { $0 * scale })), frequency: min(1, hz / 255))
		}
	}

	private static func tuple(_ v: [Float]) -> (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float) {
		let z = v + Array(repeating: 0, count: max(0, 10 - v.count))
		return (z[0], z[1], z[2], z[3], z[4], z[5], z[6], z[7], z[8], z[9])
	}

	// MARK: - Trigger emulation (Xbox trigger motors, phone)

	/// Physical trigger positions 0...1
	func triggersMoved(left: Float, right: Float) {
		guard emulatesTriggers else { return }
		queue.async {
			self.triggerValues = [left, right]
			self.updateTriggerMotors()
		}
	}

	/// On-screen L2/R2 positions 0...1
	func screenTriggersMoved(left: Float, right: Float) {
		guard emulatesTriggers else { return }
		queue.async {
			guard self.screenTriggers != [left, right] else { return }
			self.screenTriggers = [left, right]
			self.updateTriggerMotors()
		}
	}

	/// Queue. Vibration plays while the trigger sits in a vibrating zone; weapon
	/// and resistance effects become a click where the resistance would break or start.
	private func updateTriggerMotors() {
		let onTriggers = triggerMotors.count == 2
		guard onTriggers || phone != nil else { return }
		let scale = motorsEnabled ? motorTriggerScale : 0
		for side in 0..<2 {
			let p = max(triggerValues[side], screenTriggers[side])
			var out: (Float, Float) = (0, 0.5)
			var tap: (Float, Float)?
			switch motorEffects[side].kind {
			case .off:
				break
			case .vibration(let zones, let hz):
				// The phone is the whole device in your hand: only while the trigger is held
				if onTriggers || p > 0 {
					out = (zones[min(9, Int(p * 10))] * scale, Self.sharpness(hz: hz))
				}
			case .weapon(let start, let end, let strength):
				if armed[side], p >= end {
					armed[side] = false
					tap = (strength * scale, 1)
				} else if p < max(start, 0.05) {
					armed[side] = true
				}
			case .feedback(let zones):
				// A bump where the resistance starts; nothing if it starts at rest
				guard let wallZone = zones.firstIndex(where: { $0 > 0 }), wallZone > 0 else { break }
				let wall = Float(wallZone) / 10
				if armed[side], p >= wall {
					armed[side] = false
					tap = (zones[wallZone] * 0.6 * scale, 0.4)
				} else if p < wall - 0.05 {
					armed[side] = true
				}
			}
			triggerOut[side] = out
			let motor = onTriggers ? triggerMotors[side] : phone
			if onTriggers { motor?.set(intensity: out.0, sharpness: out.1) }
			if let tap { motor?.tap(intensity: tap.0 * (onTriggers ? 1 : phoneScale), sharpness: tap.1) }
		}
		flushPhone()
	}

	// MARK: - Rumble and haptics (any thread)

	/// Classic rumble: left = heavy low-frequency motor, right = light high-frequency motor (0...255)
	func rumble(left: UInt8, right: UInt8) {
		queue.async {
			self.drive(left: Float(left) / 255, right: Float(right) / 255, sharpness: (0.3, 0.8))
		}
	}

	/// DualSense haptics: 16-bit stereo PCM at 3 kHz, one channel per grip.
	/// Turned into intensity (loudness) and sharpness (pitch) per side.
	func haptics(_ samples: UnsafePointer<Int16>, frames: Int) {
		guard frames > 0 else { return }
		let left = Self.analyse(samples, frames: frames, channel: 0)
		let right = Self.analyse(samples, frames: frames, channel: 1)
		queue.async {
			self.lastHaptics = CACurrentMediaTime()
			for (side, hz) in [left.hz, right.hz].enumerated() where hz > 0 {
				self.hapticsSharpness[side] = self.hapticsSharpness[side] * 0.6 + Self.sharpness(hz: hz) * 0.4
			}
			self.drive(left: left.level, right: right.level, sharpness: (self.hapticsSharpness[0], self.hapticsSharpness[1]))
		}
	}

	/// Peak level (0...1) and dominant frequency from zero crossings (0 if unknown)
	private static func analyse(_ samples: UnsafePointer<Int16>, frames: Int, channel: Int) -> (level: Float, hz: Float) {
		var peak: Int32 = 0
		var crossings = 0
		var lastSign: Int32 = 0
		// Ignore crossings in the noise around zero
		let threshold: Int32 = 400
		for i in 0..<frames {
			let v = Int32(samples[i * 2 + channel])
			peak = max(peak, abs(v))
			let sign: Int32 = v > threshold ? 1 : (v < -threshold ? -1 : 0)
			if sign != 0 {
				if lastSign != 0, sign != lastSign { crossings += 1 }
				lastSign = sign
			}
		}
		let seconds = Float(frames) / 3000
		return (min(1, Float(peak) / 16_384), crossings > 0 ? Float(crossings) / 2 / seconds : 0)
	}

	/// DualSense haptics mostly sit between ~50 Hz (thuds) and ~350 Hz (textures, clicks)
	private static func sharpness(hz: Float) -> Float {
		min(1, max(0, (hz - 50) / 300))
	}

	/// Queue
	private func drive(left: Float, right: Float, sharpness: (Float, Float)) {
		guard motorsEnabled, !handles.isEmpty || phone != nil else { return }
		let l = left * hapticScale
		let r = right * hapticScale
		rumbleOut = [(l, sharpness.0), (r, sharpness.1)]
		if phone != nil {
			flushPhone()
		} else if handles.count == 2 {
			handles[0].set(intensity: l, sharpness: sharpness.0)
			handles[1].set(intensity: r, sharpness: sharpness.1)
		} else {
			let total = l + r
			let blended = total > 0 ? (sharpness.0 * l + sharpness.1 * r) / total : 0.5
			handles[0].set(intensity: max(l, r), sharpness: blended)
		}
	}

	/// Queue. One actuator for everything: play whatever is strongest right now.
	private func flushPhone() {
		guard let phone else { return }
		let strongest = (rumbleOut + triggerOut).max { $0.0 < $1.0 } ?? (0, 0.5)
		phone.set(intensity: motorsEnabled ? strongest.0 * phoneScale : 0, sharpness: strongest.1)
	}

	/// Queue
	private func silence() {
		rumbleOut = [(0, 0.5), (0, 0.5)]
		triggerOut = [(0, 0.5), (0, 0.5)]
		(handles + triggerMotors + [phone].compactMap { $0 }).forEach { $0.set(intensity: 0, sharpness: 0.5) }
	}

	/// Queue. Haptics arrive every 10 ms while a game plays them; if they stop
	/// without a final silent packet, don't leave the motors running.
	private func startWatchdog() {
		guard !handles.isEmpty || phone != nil else { return }
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
		timer.setEventHandler { [weak self] in
			guard let self, self.lastHaptics > 0, CACurrentMediaTime() - self.lastHaptics > 0.1 else { return }
			self.lastHaptics = 0
			self.rumbleOut = [(0, 0.5), (0, 0.5)]
			self.handles.forEach { $0.set(intensity: 0, sharpness: 0.5) }
			self.flushPhone()
		}
		timer.resume()
		watchdog = timer
	}
}

/// One haptic actuator: a continuous event whose intensity (and, on the phone,
/// sharpness) is changed as values arrive, which is cheaper than scheduling
/// new patterns. Used only on the feedback queue.
///
/// Controller engines are driven the way SDL drives them, which is known to work
/// on a DualSense: one endless event, intensity only, played only while there's
/// something to feel. The phone gets a looping pattern with sharpness as well.
private final class Motor {
	private let engine: CHHapticEngine
	private let queue: DispatchQueue
	private let name: String
	/// A game controller's actuator rather than the phone's Taptic Engine
	private let isController: Bool
	private var player: CHHapticPatternPlayer?
	/// The player is running (controllers stop it at zero)
	private var playing = false
	private var intensity: Float = 0
	private var sharpness: Float = 0.5
	private var needsRestart = false
	private var lastRestart: CFTimeInterval = 0
	private var stopped = false
	private var loggedError = false

	convenience init?(haptics: GCDeviceHaptics, locality: GCHapticsLocality, queue: DispatchQueue) {
		guard let engine = haptics.createEngine(withLocality: locality) else {
			log.error("Haptics (\(locality.rawValue, privacy: .public)): the controller has no engine for it")
			return nil
		}
		self.init(engine: engine, name: locality.rawValue, isController: true, queue: queue)
	}

	/// The phone's Taptic Engine, if it has one
	static func phone(queue: DispatchQueue) -> Motor? {
		guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
		do {
			let engine = try CHHapticEngine()
			// Don't touch the audio session the game audio runs on
			engine.playsHapticsOnly = true
			return Motor(engine: engine, name: "phone", isController: false, queue: queue)
		} catch {
			log.error("Phone haptics: \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	init?(engine: CHHapticEngine, name: String, isController: Bool, queue: DispatchQueue) {
		self.engine = engine
		self.queue = queue
		self.name = name
		self.isController = isController
		engine.isAutoShutdownEnabled = false
		// Interruptions (backgrounding, a server reset): start again on the next update
		engine.stoppedHandler = { [weak self] _ in queue.async { self?.needsRestart = true } }
		engine.resetHandler = { [weak self] in queue.async { self?.needsRestart = true } }
		do {
			try start()
		} catch {
			log.error("Haptics (\(name, privacy: .public)): \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	private func start() throws {
		try engine.start()
		playing = false
		if isController {
			let event = CHHapticEvent(
				eventType: .hapticContinuous,
				parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
				relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
			player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
			try update()
			return
		}
		let event = CHHapticEvent(
			eventType: .hapticContinuous,
			parameters: [
				CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
				CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
			], relativeTime: 0, duration: 30)
		let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
		player.loopEnabled = true
		try player.sendParameters(parameters, atTime: CHHapticTimeImmediate)
		try player.start(atTime: CHHapticTimeImmediate)
		self.player = player
		playing = true
	}

	private var parameters: [CHHapticDynamicParameter] {
		[
			CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
			// Added to the event's 0.5
			CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.5, relativeTime: 0),
		]
	}

	/// Sends the current values to the player
	private func update() throws {
		guard let player else { return }
		guard isController else {
			return try player.sendParameters(parameters, atTime: CHHapticTimeImmediate)
		}
		guard intensity > 0 else {
			if playing {
				playing = false
				try player.stop(atTime: CHHapticTimeImmediate)
			}
			return
		}
		if !playing {
			try player.start(atTime: CHHapticTimeImmediate)
			playing = true
		}
		try player.sendParameters(
			[CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)],
			atTime: CHHapticTimeImmediate)
	}

	/// Only the first failure, so a broken actuator doesn't flood the log every 10 ms
	private func logOnce(_ error: Error) {
		guard !loggedError else { return }
		loggedError = true
		log.error("Haptics (\(self.name, privacy: .public)) update failed: \(error.localizedDescription, privacy: .public)")
	}

	/// Restarts after an interruption, at most once a second
	private func ensureRunning() -> Bool {
		guard !stopped else { return false }
		guard needsRestart else { return true }
		let now = CACurrentMediaTime()
		guard now - lastRestart > 1 else { return false }
		lastRestart = now
		player = nil
		do {
			try start()
			needsRestart = false
			return true
		} catch {
			return false
		}
	}

	func set(intensity: Float, sharpness: Float) {
		let intensity = min(1, max(0, intensity))
		let sharpness = min(1, max(0, sharpness))
		// Each change is a packet to the controller: skip ones you couldn't feel
		guard abs(intensity - self.intensity) > 0.01 || abs(sharpness - self.sharpness) > 0.03 else { return }
		self.intensity = intensity
		self.sharpness = sharpness
		guard ensureRunning() else { return }
		do {
			try update()
		} catch {
			logOnce(error)
		}
	}

	/// A single short click
	func tap(intensity: Float, sharpness: Float) {
		guard intensity > 0, ensureRunning() else { return }
		var parameters = [CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, intensity))]
		if !isController {
			parameters.append(CHHapticEventParameter(parameterID: .hapticSharpness, value: min(1, max(0, sharpness))))
		}
		let event = CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: 0)
		guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
			let player = try? engine.makePlayer(with: pattern)
		else { return }
		try? player.start(atTime: CHHapticTimeImmediate)
	}

	func stop() {
		stopped = true
		if playing { try? player?.stop(atTime: CHHapticTimeImmediate) }
		playing = false
		player = nil
		engine.stop()
	}
}
