import CoreHaptics
import CoreMotion
import GameController
import NVSTKit
import simd
import SwiftUI

/// Reads the controller the same way a stream does, so what shows here is what GeForce NOW
/// would get, and plays rumble through the same path the game's rumble takes. Also tries the
/// controller's own extras (a DualSense's touchpad, lights, haptics and adaptive triggers, an
/// Xbox controller's trigger motors), which games on GeForce NOW don't use.
@Observable
final class ControllerTester {
	enum TriggerPreset: String, CaseIterable, Identifiable {
		case off, resistance, weapon, vibration

		var id: Self { self }

		var label: String {
			switch self {
			case .off: "Off"
			case .resistance: "Resistance"
			case .weapon: "Weapon"
			case .vibration: "Vibration"
			}
		}
	}

	/// Rumble or haptics playing right now, for the picture to shake along
	struct Buzz: Equatable {
		/// Per grip, 0...1
		var left: Float
		var right: Float
		/// How fast the picture shakes
		var shakeHz: Double
	}

	private(set) var pad = NVSTGamepad()
	private(set) var style = ControllerStyle.xbox
	/// Xbox Series Share button: shown, but GeForce NOW doesn't get it
	private(set) var sharePressed = false
	private(set) var controllerName: String?
	/// Where gyro aiming would read motion from, nil when it wouldn't
	private(set) var motionSource: String?
	/// Why turning the controller can't move anything in a game
	private(set) var motionUnavailableReason: String?
	private(set) var rumbleOn = "Controller"
	/// rad/s: x right, y out of the face, z towards the player
	private(set) var gyro = SIMD3<Float>.zero
	/// How the controller has turned lately, in the 3D model's axes
	/// (x right, y towards the triggers, z out of the face). Settles back to front-on.
	private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
	private(set) var buzz: Buzz?

	// PlayStation controllers
	private(set) var hasTouchpad = false
	private(set) var hasAdaptiveTriggers = false
	private(set) var hasLight = false
	/// The controller's own touchpad fingers, 0...1 across and down
	private(set) var touches: [CGPoint?] = [nil, nil]
	private(set) var touchpadPressed = false
	/// Fingers on the touchpad on screen, by slot, 0...1 across and down
	private(set) var screenTouches: [Int: CGPoint] = [:]
	/// A tap on the touchpad on screen
	private(set) var screenClick = false
	private(set) var triggerPreset = TriggerPreset.off
	private(set) var lightbar: CGColor?
	private(set) var player: Int?

	// Xbox controllers
	private(set) var hasTriggerMotors = false
	/// Left and right trigger motors playing, 0...1
	private(set) var triggerRumble = SIMD2<Float>.zero

	var touchpadClicked: Bool { touchpadPressed || screenClick }

	/// View + Menu held for a second, as in a stream
	@ObservationIgnored var onMenuCombo: (() -> Void)?

	@ObservationIgnored private let input = ControllerInput()
	@ObservationIgnored private weak var lastController: GCController?
	@ObservationIgnored private var running = false
	@ObservationIgnored private var gyroAimSetting = false
	@ObservationIgnored private var rumbleStop: DispatchWorkItem?
	@ObservationIgnored private var buzzEnd: DispatchWorkItem?
	@ObservationIgnored private var triggerRumbleEnd: DispatchWorkItem?
	@ObservationIgnored private var screenClickEnd: DispatchWorkItem?
	/// One-shot haptic engines still playing
	@ObservationIgnored private var hapticEngines: [CHHapticEngine] = []
	/// The lights as they were, put back on the way out
	@ObservationIgnored private var originalLight: GCColor?
	@ObservationIgnored private var originalPlayer = GCControllerPlayerIndex.indexUnset
	@ObservationIgnored private var changedLights = false
	// Motion, on the main thread: integrated every sample, shown at most 60 times a second
	@ObservationIgnored private var attitude = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
	@ObservationIgnored private var lastTimestamp: UInt32?
	@ObservationIgnored private var lastShown: CFTimeInterval = 0

	private static let phoneHasMotion = CMMotionManager().isDeviceMotionAvailable
	private static var deviceNoun: String { DeviceLayout.isPad ? "iPad" : "phone" }

	func isPressed(_ button: UInt16) -> Bool { pad.buttons & button != 0 }

	func start(settings: StreamSettings, orientation: UIInterfaceOrientation?) {
		guard !running else { return }
		running = true
		gyroAimSetting = settings.gyroAim != .off
		input.feedback.rumbleEnabled = settings.rumble
		input.feedback.phoneHapticsScale = settings.phoneHaptics.scale
		if let orientation { input.interfaceOrientation = orientation }
		input.onPad = { [weak self] pad in
			guard let self else { return }
			self.pad = pad
			if self.input.activeController !== self.lastController { self.refreshController() }
		}
		input.onGyroAim = { [weak self] gyro, timestamp in self?.motion(gyro, timestamp: timestamp) }
		input.onMenuCombo = { [weak self] in self?.onMenuCombo?() }
		input.start()
		refreshController()
	}

	func stop() {
		guard running else { return }
		running = false
		stopBuzz()
		screenClickEnd?.cancel()
		restoreController(lastController)
		watchExtras(nil)
		hapticEngines.forEach { $0.stop() }
		hapticEngines.removeAll()
		input.stop()
		input.onPad = nil
		input.onGyroAim = nil
		input.onMenuCombo = nil
	}

	private func refreshController() {
		restoreController(lastController)
		let controller = input.activeController
		lastController = controller
		style = ControllerStyle(controller)
		controllerName = input.controllerName ?? (controller != nil ? "Controller" : nil)

		let controllerGyro = controller?.motion?.hasRotationRate == true
		// The same motion gyro aiming would use: the controller's own, or the phone's while gyro aiming is on
		input.gyroAimEnabled = controllerGyro || gyroAimSetting
		if controllerGyro {
			motionSource = "Controller gyro"
			motionUnavailableReason = nil
		} else if gyroAimSetting && Self.phoneHasMotion {
			motionSource = DeviceLayout.isPad ? "iPad gyro" : "Phone gyro"
			motionUnavailableReason = nil
		} else {
			motionSource = nil
			motionUnavailableReason = controller == nil || !Self.phoneHasMotion
				? "No motion sensors to read."
				: "This controller has no motion sensors. Turn on Gyro aiming to use the \(Self.deviceNoun)'s instead."
		}

		let localities = controller?.haptics?.supportedLocalities ?? []
		if !localities.isEmpty {
			rumbleOn = "Controller"
		} else {
			rumbleOn = CHHapticEngine.capabilitiesForHardware().supportsHaptics ? (DeviceLayout.isPad ? "iPad" : "Phone") : "None"
		}
		hasTriggerMotors = localities.contains(.leftTrigger) && localities.contains(.rightTrigger)
		hasAdaptiveTriggers = controller?.extendedGamepad is GCDualSenseGamepad
		hasLight = controller?.light != nil
		originalLight = controller?.light?.color
		originalPlayer = controller?.playerIndex ?? .indexUnset
		changedLights = false
		lightbar = nil
		player = nil
		triggerPreset = .off
		watchExtras(controller)

		attitude = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
		lastTimestamp = nil
		orientation = attitude
		gyro = .zero
	}

	/// Puts the lights and triggers back how they were
	private func restoreController(_ controller: GCController?) {
		guard let controller else { return }
		if let triggers = controller.extendedGamepad as? GCDualSenseGamepad, triggerPreset != .off {
			triggers.leftTrigger.setModeOff()
			triggers.rightTrigger.setModeOff()
		}
		if changedLights {
			if let originalLight { controller.light?.color = originalLight }
			controller.playerIndex = originalPlayer
		}
	}

	// MARK: - Buttons the stream doesn't read

	/// The Share button and the touchpad aren't part of the pad the stream reads, so they're watched on their own
	@ObservationIgnored private weak var shareButton: GCControllerButtonInput?
	@ObservationIgnored private weak var touchpadButton: GCControllerButtonInput?
	@ObservationIgnored private var touchpadFingers: [GCControllerDirectionPad] = []

	private func watchExtras(_ controller: GCController?) {
		shareButton?.pressedChangedHandler = nil
		touchpadButton?.pressedChangedHandler = nil
		touchpadFingers.forEach { $0.valueChangedHandler = nil }

		let gamepad = controller?.extendedGamepad
		shareButton = (gamepad as? GCXboxGamepad)?.buttonShare
		switch gamepad {
		case let ds as GCDualSenseGamepad:
			touchpadButton = ds.touchpadButton
			touchpadFingers = [ds.touchpadPrimary, ds.touchpadSecondary]
		case let ds4 as GCDualShockGamepad:
			touchpadButton = ds4.touchpadButton
			touchpadFingers = [ds4.touchpadPrimary, ds4.touchpadSecondary]
		default:
			touchpadButton = nil
			touchpadFingers = []
		}
		hasTouchpad = !touchpadFingers.isEmpty
		sharePressed = false
		touchpadPressed = false
		touches = [nil, nil]

		shareButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.sharePressed = pressed }
		touchpadButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.touchpadPressed = pressed }
		for (slot, finger) in touchpadFingers.enumerated() {
			finger.valueChangedHandler = { [weak self] _, x, y in
				// Lifting the finger puts it back to the middle, exactly
				self?.touches[slot] = x == 0 && y == 0 ? nil : CGPoint(x: Double(x + 1) / 2, y: Double(1 - y) / 2)
			}
		}
	}

	// MARK: - Motion

	/// `gyro` in rad/s, x right, y out of the face, z towards the player. Turns the model with it,
	/// easing back to front-on so it never drifts off (there's no gravity here to keep it level).
	private func motion(_ gyro: SIMD3<Float>, timestamp: UInt32) {
		defer { lastTimestamp = timestamp }
		guard let last = lastTimestamp else { return }
		let dt = min(0.05, Float(timestamp &- last) / 1_000_000)
		guard dt > 0 else { return }
		// Controller (x, y, z) is the model's (x, -z, y): z towards the player is down the model
		let w = SIMD3(gyro.x, -gyro.z, gyro.y)
		let rate = simd_length(w)
		if rate > 0 {
			attitude = simd_normalize(attitude * simd_quatf(angle: rate * dt, axis: w / rate))
		}
		attitude = simd_slerp(attitude, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), min(1, dt / 1.5))

		let now = CACurrentMediaTime()
		guard now - lastShown > 1.0 / 60 else { return }
		lastShown = now
		self.gyro = gyro
		orientation = attitude
	}

	// MARK: - Touchpad on screen

	func screenTouch(_ event: ControllerSceneView.PadTouch) {
		switch event {
		case .down(let slot, let x, let y), .move(let slot, let x, let y):
			screenTouches[slot] = CGPoint(x: Double(x), y: Double(y))
		case .up(let slot):
			screenTouches[slot] = nil
		case .tap(let slot):
			screenClickEnd?.cancel()
			screenClick = true
			let end = DispatchWorkItem { [weak self] in
				self?.screenClick = false
				self?.screenTouches[slot] = nil
			}
			screenClickEnd = end
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: end)
		}
	}

	// MARK: - Rumble and haptics

	/// Rumble for a moment, the way a game's rumble plays: low is the heavy motor (left grip),
	/// high the light one (right grip)
	func rumble(low: Float, high: Float) {
		stopBuzz()
		input.feedback.rumble(low: low, high: high)
		let stop = DispatchWorkItem { [weak self] in self?.input.feedback.rumble(low: 0, high: 0) }
		rumbleStop = stop
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: stop)
		showBuzz(Buzz(left: low, right: high, shakeHz: low > 0 ? 16 : 30))
	}

	/// A moment of haptics on the whole controller (or the phone): low and soft, or high and sharp
	func haptics(sharp: Bool) {
		stopBuzz()
		play(.default, sharpness: sharp ? 1 : 0.05)
		showBuzz(Buzz(left: 1, right: 1, shakeHz: sharp ? 32 : 13))
	}

	/// An Xbox controller's motor in one trigger
	func triggerMotor(left: Bool) {
		play(left ? .leftTrigger : .rightTrigger, sharpness: 0.5)
		triggerRumble = left ? SIMD2(1, 0) : SIMD2(0, 1)
		triggerRumbleEnd?.cancel()
		let end = DispatchWorkItem { [weak self] in self?.triggerRumble = .zero }
		triggerRumbleEnd = end
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: end)
	}

	/// 0.6 s of haptics on the controller's `locality`, or the phone's if the controller can't
	private func play(_ locality: GCHapticsLocality, sharpness: Float) {
		let engine: CHHapticEngine?
		if let haptics = lastController?.haptics, haptics.supportedLocalities.contains(locality) {
			engine = haptics.createEngine(withLocality: locality)
		} else if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
			engine = try? CHHapticEngine()
			engine?.playsHapticsOnly = true
		} else {
			engine = nil
		}
		guard let engine else { return }
		do {
			try engine.start()
			let event = CHHapticEvent(
				eventType: .hapticContinuous,
				parameters: [
					CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
					CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
				], relativeTime: 0, duration: 0.6)
			try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: CHHapticTimeImmediate)
		} catch {
			log.error("Controller test haptics: \(error.localizedDescription, privacy: .public)")
			return
		}
		hapticEngines.append(engine)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak engine] in
			engine?.stop()
			self?.hapticEngines.removeAll { $0 === engine }
		}
	}

	private func showBuzz(_ buzz: Buzz) {
		self.buzz = buzz
		let end = DispatchWorkItem { [weak self] in self?.buzz = nil }
		buzzEnd = end
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: end)
	}

	private func stopBuzz() {
		rumbleStop?.cancel()
		rumbleStop = nil
		buzzEnd?.cancel()
		buzzEnd = nil
		buzz = nil
		input.feedback.rumble(low: 0, high: 0)
	}

	// MARK: - DualSense extras

	func setTriggers(_ preset: TriggerPreset) {
		triggerPreset = preset
		guard let pad = lastController?.extendedGamepad as? GCDualSenseGamepad else { return }
		for trigger in [pad.leftTrigger, pad.rightTrigger] {
			switch preset {
			case .off: trigger.setModeOff()
			case .resistance: trigger.setModeFeedbackWithStartPosition(0.3, resistiveStrength: 0.75)
			case .weapon: trigger.setModeWeaponWithStartPosition(0.2, endPosition: 0.6, resistiveStrength: 1)
			case .vibration: trigger.setModeVibrationWithStartPosition(0, amplitude: 1, frequency: 0.3)
			}
		}
	}

	func setLightbar(red: UInt8, green: UInt8, blue: UInt8) {
		let (r, g, b) = (Float(red) / 255, Float(green) / 255, Float(blue) / 255)
		lightbar = red == 0 && green == 0 && blue == 0
			? nil : CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
		changedLights = true
		lastController?.light?.color = GCColor(red: r, green: g, blue: b)
	}

	func setPlayer(_ number: Int) {
		player = number
		changedLights = true
		lastController?.playerIndex = GCControllerPlayerIndex(rawValue: number - 1) ?? .indexUnset
	}
}

struct ControllerTestView: View {
	/// Set when opened during a stream: true on open so the stream lets go of the controller, false on close
	var onActiveChange: ((Bool) -> Void)?
	/// View + Menu held, for closing without touching the screen
	var onClose: (() -> Void)?

	@Environment(SettingsStore.self) private var store
	@State private var tester = ControllerTester()

	private static let lightbarColors: [(name: String, r: UInt8, g: UInt8, b: UInt8)] = [
		("Red", 255, 0, 0), ("Green", 0, 255, 0), ("Blue", 0, 0, 255),
		("Purple", 160, 0, 255), ("White", 255, 255, 255), ("Off", 0, 0, 0),
	]

	private var style: ControllerStyle { tester.style }
	private var deviceNoun: String { DeviceLayout.isPad ? "iPad" : "phone" }

	private var buttonNames: [(UInt16, String)] {
		[
			(NVSTGamepad.a, style.a), (NVSTGamepad.b, style.b), (NVSTGamepad.x, style.x), (NVSTGamepad.y, style.y),
			(NVSTGamepad.dpadUp, "Up"), (NVSTGamepad.dpadDown, "Down"), (NVSTGamepad.dpadLeft, "Left"), (NVSTGamepad.dpadRight, "Right"),
			(NVSTGamepad.leftShoulder, style.lb), (NVSTGamepad.rightShoulder, style.rb),
			(NVSTGamepad.leftThumb, style.leftStickClick), (NVSTGamepad.rightThumb, style.rightStickClick),
			(NVSTGamepad.back, style.view), (NVSTGamepad.start, style.menu), (NVSTGamepad.guide, style.home),
		]
	}

	private var pressedText: String {
		var names = buttonNames.filter { tester.isPressed($0.0) }.map(\.1)
		if tester.pad.leftTrigger > 0 { names.append(style.lt) }
		if tester.pad.rightTrigger > 0 { names.append(style.rt) }
		if tester.sharePressed { names.append("Share (not sent)") }
		if tester.touchpadPressed { names.append("Touchpad (not sent)") }
		if tester.screenClick { names.append("Touchpad tap") }
		return names.isEmpty ? "None" : names.joined(separator: ", ")
	}

	private var touchText: String {
		let points = tester.touches.compactMap { $0 } + tester.screenTouches.sorted { $0.key < $1.key }.map(\.value)
		guard !points.isEmpty else { return "None" }
		return points.map { String(format: "%.2f, %.2f", $0.x, $0.y) }.joined(separator: "  ·  ")
	}

	private static let controls: [(UInt16, ControllerScene.Control)] = [
		(NVSTGamepad.a, .a), (NVSTGamepad.b, .b), (NVSTGamepad.x, .x), (NVSTGamepad.y, .y),
		(NVSTGamepad.dpadUp, .up), (NVSTGamepad.dpadDown, .down), (NVSTGamepad.dpadLeft, .left), (NVSTGamepad.dpadRight, .right),
		(NVSTGamepad.leftShoulder, .lb), (NVSTGamepad.rightShoulder, .rb),
		(NVSTGamepad.leftThumb, .leftStick), (NVSTGamepad.rightThumb, .rightStick),
		(NVSTGamepad.back, .view), (NVSTGamepad.start, .menu), (NVSTGamepad.guide, .home),
	]

	/// What the 3D controller shows
	private var sceneState: ControllerScene.State {
		var s = ControllerScene.State()
		s.pressed = Set(Self.controls.filter { tester.isPressed($0.0) }.map(\.1))
		if tester.sharePressed { s.pressed.insert(.share) }
		if tester.touchpadClicked { s.pressed.insert(.touchpad) }
		let pad = tester.pad
		// The pad is y-up; the model tips +y down
		s.leftStick = SIMD2(Float(pad.leftX) / 32767, -Float(pad.leftY) / 32767)
		s.rightStick = SIMD2(Float(pad.rightX) / 32767, -Float(pad.rightY) / 32767)
		s.lt = Float(pad.leftTrigger) / 255
		s.rt = Float(pad.rightTrigger) / 255
		s.orientation = tester.orientation
		s.touches = tester.touches.compactMap { $0 }.map { .init(x: Float($0.x), y: Float($0.y), fromScreen: false) }
			+ tester.screenTouches.sorted { $0.key < $1.key }.map { .init(x: Float($0.value.x), y: Float($0.value.y), fromScreen: true) }
		s.lightbar = tester.lightbar
		s.player = tester.player
		s.triggerLook = switch tester.triggerPreset {
		case .off: .off
		case .resistance: .resistance
		case .weapon: .weapon
		case .vibration: .vibration
		}
		s.triggerRumble = tester.triggerRumble
		s.buzz = tester.buzz.map { .init(left: $0.left, right: $0.right, hz: $0.shakeHz) }
		return s
	}

	var body: some View {
		GeometryReader { geo in
			let landscape = geo.size.width > geo.size.height
			VStack(spacing: 0) {
				live
					.frame(height: landscape ? geo.size.height * 0.6 : min(geo.size.height * 0.5, geo.size.width / 1.3))
				form
			}
		}
		.background(Color(.systemGroupedBackground))
		.navigationTitle("Controller Test")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear {
			onActiveChange?(true)
			let orientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation
			tester.onMenuCombo = onClose
			tester.start(settings: store.settings, orientation: orientation)
		}
		.onDisappear {
			tester.stop()
			onActiveChange?(false)
		}
	}

	/// The 3D controller, kept on screen above the list
	private var live: some View {
		ControllerSceneView(model: style.isPlayStation ? .dualSense : .xbox, state: sceneState,
			onTouch: { tester.screenTouch($0) })
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.accessibilityLabel("Controller, showing what's pressed. Drag to turn it.")
	}

	private var form: some View {
		Form {
			Section {
				LabeledContent("Pressed", value: pressedText)
				if tester.hasTouchpad {
					LabeledContent("Touchpad", value: touchText)
				}
				LabeledContent("Left stick", value: Self.stick(tester.pad.leftX, tester.pad.leftY))
				LabeledContent("Right stick", value: Self.stick(tester.pad.rightX, tester.pad.rightY))
				LabeledContent("\(style.lt) / \(style.rt)", value: "\(Self.percent(tester.pad.leftTrigger)) / \(Self.percent(tester.pad.rightTrigger))")
			} header: {
				Text(tester.controllerName ?? "No controller")
			} footer: {
				Text("Buttons light up as GeForce NOW gets them. Games see an Xbox controller, so \(style.isPlayStation ? "\(style.a) is A, \(style.b) is B, \(style.x) is X and \(style.y) is Y" : "a PlayStation controller's Cross is A, Circle is B, Square is X and Triangle is Y").")
				Text("If the \(style.home) button doesn't light up, iOS is keeping it for itself. Tap the top-left corner of the stream for an on-screen Xbox button instead.")
				if tester.hasTouchpad {
					Text("Fingers on the controller's touchpad show in orange. Touch the touchpad on screen to draw on it, or tap it to click. Games on GeForce NOW don't get the touchpad.")
				}
				Text("Drag the controller to look at it from another side. Hold \(style.view) + \(style.menu) for a second to close this screen.")
				if onActiveChange != nil {
					Text("While this screen is open, the game doesn't get anything from your controller, and its rumble doesn't reach it.")
				}
			}

			Section {
				if tester.motionSource != nil {
					AxisRow(label: "Pitch", value: tester.gyro.x * 180 / .pi, range: 360, format: "%+.0f°/s")
					AxisRow(label: "Yaw", value: tester.gyro.y * 180 / .pi, range: 360, format: "%+.0f°/s")
					AxisRow(label: "Roll", value: tester.gyro.z * 180 / .pi, range: 360, format: "%+.0f°/s")
				} else {
					Text(tester.motionUnavailableReason ?? "No motion sensors to read.")
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Motion: \(tester.motionSource ?? "none")")
			} footer: {
				if tester.motionSource != nil {
					Text("This is the motion gyro aiming uses. Held still, it should read near zero. The controller on screen turns as you turn yours and settles back to facing you.")
				}
			}

			Section {
				Button("Rumble left (heavy motor)") { tester.rumble(low: 1, high: 0) }
				Button("Rumble right (light motor)") { tester.rumble(low: 0, high: 1) }
				Button("Rumble both") { tester.rumble(low: 1, high: 1) }
				Button("Haptics: low thud") { tester.haptics(sharp: false) }
				Button("Haptics: high buzz") { tester.haptics(sharp: true) }
			} header: {
				Text("Rumble: \(store.settings.rumble ? tester.rumbleOn : "off in settings")")
			} footer: {
				if store.settings.rumble {
					Text("Rumble plays the way a game's rumble does. Controllers without motors, like a Backbone, rumble the \(deviceNoun) instead. Haptics try the controller's own haptics, which games on GeForce NOW don't use.")
				} else {
					Text("Rumble is off in Controller settings, so the rumble tests don't vibrate. The picture still shakes to show they were sent.")
				}
			}

			if tester.hasTriggerMotors {
				Section {
					Button("Left trigger motor") { tester.triggerMotor(left: true) }
					Button("Right trigger motor") { tester.triggerMotor(left: false) }
				} header: {
					Text("Trigger motors")
				} footer: {
					Text("Xbox controllers have a small motor in each trigger. Games on GeForce NOW don't use them.")
				}
			}

			if style.isPlayStation {
				Section {
					Picker("Effect", selection: Binding(get: { tester.triggerPreset }, set: { tester.setTriggers($0) })) {
						ForEach(ControllerTester.TriggerPreset.allCases) { Text($0.label).tag($0) }
					}
					.disabled(!tester.hasAdaptiveTriggers)
				} header: {
					Text("Adaptive triggers")
				} footer: {
					if tester.hasAdaptiveTriggers {
						Text("Pull \(style.lt) or \(style.rt) to feel it. Resistance pushes back from a third of the way down, Weapon resists then gives way like a gun trigger, and Vibration buzzes. Games on GeForce NOW don't use them, and leaving this screen turns them off.")
					} else {
						Text("Only a DualSense has adaptive triggers.")
					}
				}

				Section {
					HStack(spacing: 12) {
						ForEach(Self.lightbarColors, id: \.name) { c in
							Button {
								tester.setLightbar(red: c.r, green: c.g, blue: c.b)
							} label: {
								Circle()
									.fill(Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255))
									.overlay(Circle().stroke(Color(.separator)))
									.frame(width: 32, height: 32)
							}
							.buttonStyle(.borderless)
							.accessibilityLabel(c.name)
						}
					}
					.disabled(!tester.hasLight)
					Picker("Player", selection: Binding(get: { tester.player ?? 0 }, set: { tester.setPlayer($0) })) {
						ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
					}
					.pickerStyle(.segmented)
				} header: {
					Text("Lightbar and player lights")
				} footer: {
					Text(tester.hasLight ? "Leaving this screen puts the lights back how they were." : "This controller has no lightbar iOS can change.")
				}
			}
		}
	}

	private static func stick(_ x: Int16, _ y: Int16) -> String {
		String(format: "%+.2f, %+.2f", Double(x) / 32767, Double(y) / 32767)
	}

	private static func percent(_ v: UInt8) -> String {
		"\(Int((Double(v) / 255 * 100).rounded()))%"
	}
}

private struct LendControllerKey: EnvironmentKey {
	static let defaultValue: ((Bool) -> Void)? = nil
}

extension EnvironmentValues {
	/// Set during a stream: the Controller Test calls it with true when it opens, so the stream
	/// lets go of the controller, and false when it closes
	var lendController: ((Bool) -> Void)? {
		get { self[LendControllerKey.self] }
		set { self[LendControllerKey.self] = newValue }
	}
}

/// A settings row that opens the Controller Test over the whole screen, so dragging the
/// controller can't pull a settings sheet around
struct ControllerTestLink: View {
	@Binding var isPresented: Bool
	var onActiveChange: ((Bool) -> Void)?

	var body: some View {
		Button { isPresented = true } label: {
			HStack {
				Label("Controller Test", systemImage: "gamecontroller")
				Spacer()
				Image(systemName: "chevron.right")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.tertiary)
			}
			.contentShape(Rectangle())
		}
		.foregroundStyle(.primary)
		.fullScreenCover(isPresented: $isPresented) {
			NavigationStack {
				ControllerTestView(onActiveChange: onActiveChange, onClose: { isPresented = false })
					.toolbar {
						ToolbarItem(placement: .confirmationAction) {
							Button("Done") { isPresented = false }
						}
					}
			}
		}
	}
}

/// A bar from the centre for a signed value
private struct AxisRow: View {
	let label: String
	let value: Float
	let range: Float
	let format: String

	var body: some View {
		HStack(spacing: 12) {
			Text(label).frame(width: 64, alignment: .leading)
			GeometryReader { geo in
				let half = geo.size.width / 2
				let f = CGFloat(max(-1, min(1, value / range)))
				ZStack(alignment: .leading) {
					Capsule().fill(Color(.systemGray5))
					Rectangle().fill(Color.accentColor)
						.frame(width: abs(f) * half)
						.offset(x: f >= 0 ? half : half + f * half)
					Rectangle().fill(Color(.systemGray2)).frame(width: 1).offset(x: half)
				}
			}
			.frame(height: 8)
			Text(String(format: format, value))
				.monospacedDigit()
				.foregroundStyle(.secondary)
				.frame(width: 76, alignment: .trailing)
		}
		.font(.subheadline)
	}
}
