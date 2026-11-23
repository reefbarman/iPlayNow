import ChiakiKit
import CoreMotion
import GameController
import os
import UIKit

/// Maps the connected game controller to chiaki's DualSense state.
///
/// - Buttons are mapped by position (A/bottom = Cross, B/right = Circle, ...).
/// - The Home/PS button and the other system buttons are claimed from iOS so
///   pressing PS opens the PS5 menu instead of the iOS overlay.
/// - Motion comes from the controller if it has sensors (DualSense, DualShock 4,
///   GameSir G8+ in its DualShock 4 mode), otherwise from the phone (e.g. a Backbone).
final class ControllerInput {
	/// Called on the main thread with the latest pad state.
	var onPad: ((CKPadState) -> Void)?
	/// gyro rad/s, accel g, DualSense axes, monotonic microseconds.
	var onMotion: ((SIMD3<Float>, SIMD3<Float>, UInt32) -> Void)?
	var onTouch: ((TouchEvent) -> Void)?
	/// Gyro aiming, on the main thread: gyro rad/s in DualSense axes and the sensor's microseconds
	var onGyroAim: ((SIMD3<Float>, UInt32) -> Void)?
	/// Select + Start held for a second
	var onMenuCombo: (() -> Void)?

	enum TouchEvent {
		case down(slot: Int, x: UInt16, y: UInt16)
		case move(slot: Int, x: UInt16, y: UInt16)
		case up(slot: Int)
	}

	var selectIsTouchpad = false
	var phoneMotionEnabled = true

	/// Gyro aiming: motion goes to `onGyroAim` instead, and the console sees a
	/// controller held still so the game's own motion controls stay put.
	/// Uses the phone's gyro when the controller has none, even with phone motion off.
	var gyroAimEnabled = false {
		didSet {
			guard gyroAimEnabled != oldValue else { return }
			let enabled = gyroAimEnabled
			gyroAim.withLock { $0 = enabled }
			// Before start() pickController sorts out the motion source
			guard !observers.isEmpty, controller?.motion?.hasRotationRate != true else { return }
			if enabled {
				startPhoneMotion()
			} else if !phoneMotionEnabled {
				motionManager.stopDeviceMotionUpdates()
			}
		}
	}
	/// `gyroAimEnabled` for the motion queue
	private let gyroAim = OSAllocatedUnfairLock(initialState: false)
	/// Takes the gyro's resting reading off, for whichever motion source is in use
	private let calibration = OSAllocatedUnfairLock(initialState: GyroCalibration())

	private(set) var controllerName: String?
	private var controller: GCController?
	/// The controller being read, if any
	var activeController: GCController? { controller }
	private let motionManager = CMMotionManager()
	private let motionQueue = OperationQueue()
	private var observers: [NSObjectProtocol] = []
	private var touchDown = [false, false]
	private var comboTimer: Timer?
	private var lastPad = CKPadState()

	/// Rumble, haptics, adaptive triggers, lightbar and player LEDs
	let feedback = ControllerFeedback()

	init() {
		motionQueue.maxConcurrentOperationCount = 1
		motionQueue.qualityOfService = .userInteractive
	}

	func start() {
		GCController.shouldMonitorBackgroundEvents = false
		observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
			self?.pickController()
		})
		observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
			self?.pickController()
		})
		// Phone haptics until (unless) a controller with its own turns up
		feedback.attach(nil)
		pickController()
	}

	func stop() {
		suspend()
		feedback.reset()
	}

	/// Lets go of the controller but remembers what the console last asked for,
	/// so `start()` puts the lightbar, player lights and trigger effects back
	func suspend() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers.removeAll()
		comboTimer?.invalidate()
		comboTimer = nil
		motionManager.stopDeviceMotionUpdates()
		if let controller {
			restoreSystemGestures(controller)
			controller.extendedGamepad?.valueChangedHandler = nil
			controller.motion?.valueChangedHandler = nil
			controller.motion?.sensorsActive = false
		}
		controller = nil
		controllerName = nil
		lastPad = CKPadState()
		releaseTouchpad()
		feedback.detach()
	}

	// MARK: - Controller selection

	private static var candidates: [GCController] {
		GCController.controllers().filter { $0.extendedGamepad != nil }
	}

	static var hasSupportedController: Bool { !candidates.isEmpty }

	private func pickController() {
		let candidates = Self.candidates
		let next = GCController.current.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
		guard next !== controller else {
			if next == nil { startPhoneMotion() }
			return
		}

		if let controller {
			restoreSystemGestures(controller)
			controller.extendedGamepad?.valueChangedHandler = nil
			controller.motion?.valueChangedHandler = nil
			controller.motion?.sensorsActive = false
			updateMenuCombo(select: false, start: false)
			releaseTouchpad()
		}
		controller = next
		controllerName = next?.vendorName
		calibration.withLock { $0.reset() }
		feedback.attach(next)
		guard let next, let pad = next.extendedGamepad else {
			lastPad = CKPadState()
			onPad?(lastPad)
			startPhoneMotion()
			return
		}
		log.notice("Using controller: \(next.vendorName ?? "?", privacy: .public) (\(next.productCategory, privacy: .public))")

		claimSystemGestures(next)
		pad.valueChangedHandler = { [weak self] pad, _ in
			guard let self, self.controller?.extendedGamepad === pad else { return }
			self.padChanged(pad)
		}

		if let motion = next.motion, motion.hasRotationRate {
			motionManager.stopDeviceMotionUpdates()
			motion.sensorsActive = true
			motion.valueChangedHandler = { [weak self] motion in self?.controllerMotion(motion) }
		} else {
			startPhoneMotion()
		}
		padChanged(pad)
	}

	private func claimSystemGestures(_ controller: GCController) {
		for button in controller.physicalInputProfile.buttons.values {
			button.preferredSystemGestureState = .disabled
		}
	}

	private func restoreSystemGestures(_ controller: GCController) {
		for button in controller.physicalInputProfile.buttons.values {
			button.preferredSystemGestureState = .enabled
		}
	}

	// MARK: - Buttons and sticks

	private func padChanged(_ pad: GCExtendedGamepad) {
		var b: UInt32 = 0
		func set(_ pressed: Bool, _ flag: CKButton) { if pressed { b |= flag.rawValue } }

		set(pad.buttonA.isPressed, CK_BUTTON_CROSS)
		set(pad.buttonB.isPressed, CK_BUTTON_MOON)
		set(pad.buttonX.isPressed, CK_BUTTON_BOX)
		set(pad.buttonY.isPressed, CK_BUTTON_PYRAMID)
		set(pad.dpad.left.isPressed, CK_BUTTON_DPAD_LEFT)
		set(pad.dpad.right.isPressed, CK_BUTTON_DPAD_RIGHT)
		set(pad.dpad.up.isPressed, CK_BUTTON_DPAD_UP)
		set(pad.dpad.down.isPressed, CK_BUTTON_DPAD_DOWN)
		set(pad.leftShoulder.isPressed, CK_BUTTON_L1)
		set(pad.rightShoulder.isPressed, CK_BUTTON_R1)
		set(pad.leftThumbstickButton?.isPressed ?? false, CK_BUTTON_L3)
		set(pad.rightThumbstickButton?.isPressed ?? false, CK_BUTTON_R3)
		set(pad.buttonMenu.isPressed, CK_BUTTON_OPTIONS)
		set(pad.buttonHome?.isPressed ?? false, CK_BUTTON_PS)

		let selectPressed = pad.buttonOptions?.isPressed ?? false
		if let ds = pad as? GCDualSenseGamepad {
			set(selectPressed, CK_BUTTON_SHARE)
			set(ds.touchpadButton.isPressed, CK_BUTTON_TOUCHPAD)
			dualSenseTouch(ds)
		} else {
			set(selectPressed, selectIsTouchpad ? CK_BUTTON_TOUCHPAD : CK_BUTTON_SHARE)
		}

		var state = CKPadState()
		state.buttons = b
		state.l2 = UInt8(clamping: Int((pad.leftTrigger.value * 255).rounded()))
		state.r2 = UInt8(clamping: Int((pad.rightTrigger.value * 255).rounded()))
		state.left_x = Self.axis(pad.leftThumbstick.xAxis.value)
		state.left_y = Self.axis(-pad.leftThumbstick.yAxis.value)
		state.right_x = Self.axis(pad.rightThumbstick.xAxis.value)
		state.right_y = Self.axis(-pad.rightThumbstick.yAxis.value)

		lastPad = state
		onPad?(state)
		feedback.triggersMoved(left: pad.leftTrigger.value, right: pad.rightTrigger.value)
		updateMenuCombo(select: selectPressed, start: pad.buttonMenu.isPressed)
	}

	private static func axis(_ v: Float) -> Int16 {
		Int16(clamping: Int((v * 32767).rounded()))
	}

	private func updateMenuCombo(select: Bool, start: Bool) {
		if select && start {
			guard comboTimer == nil else { return }
			comboTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
				self?.comboTimer = nil
				self?.onMenuCombo?()
			}
		} else {
			comboTimer?.invalidate()
			comboTimer = nil
		}
	}

	// MARK: - DualSense touchpad

	private func releaseTouchpad() {
		for slot in touchDown.indices where touchDown[slot] {
			touchDown[slot] = false
			onTouch?(.up(slot: slot))
		}
	}

	private func dualSenseTouch(_ ds: GCDualSenseGamepad) {
		for (slot, pad) in [ds.touchpadPrimary, ds.touchpadSecondary].enumerated() {
			let x = pad.xAxis.value
			let y = pad.yAxis.value
			let touching = x != 0 || y != 0
			let px = UInt16(clamping: Int(((x + 1) / 2 * 1919).rounded()))
			let py = UInt16(clamping: Int(((1 - y) / 2 * 1079).rounded()))
			if touching && !touchDown[slot] {
				touchDown[slot] = true
				onTouch?(.down(slot: slot, x: px, y: py))
			} else if touching {
				onTouch?(.move(slot: slot, x: px, y: py))
			} else if touchDown[slot] {
				touchDown[slot] = false
				onTouch?(.up(slot: slot))
			}
		}
	}

	// MARK: - Motion

	private func controllerMotion(_ motion: GCMotion) {
		// GameController's rotation axes for a controller are x right, y towards the
		// player, z up. Reorder to the DualSense's (x right, y up, z towards the player),
		// as SDL does (src/joystick/apple/SDL_mfijoystick.m).
		let r = motion.rotationRate
		let gyro = SIMD3<Float>(Float(r.x), Float(r.z), Float(-r.y))
		// A DualSense only reports raw acceleration: gravity and userAcceleration stay zero
		let a: GCAcceleration
		if motion.hasGravityAndUserAcceleration {
			let g = motion.gravity
			let u = motion.userAcceleration
			a = GCAcceleration(x: g.x + u.x, y: g.y + u.y, z: g.z + u.z)
		} else {
			a = motion.acceleration
		}
		let accel = -SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
		sendMotion(gyro: gyro, accel: accel, timestamp: Self.nowMicros())
	}

	/// Any thread
	private func sendMotion(gyro rawGyro: SIMD3<Float>, accel: SIMD3<Float>, timestamp: UInt32) {
		let gyro = calibration.withLock { $0.update(gyro: rawGyro, accel: accel, timestamp: timestamp) }
		guard gyroAim.withLock({ $0 }) else {
			onMotion?(gyro, accel, timestamp)
			return
		}
		// Flat and still, as chiaki starts out
		onMotion?(.zero, SIMD3(0, 1, 0), timestamp)
		if Thread.isMainThread {
			onGyroAim?(gyro, timestamp)
		} else {
			DispatchQueue.main.async { [weak self] in self?.onGyroAim?(gyro, timestamp) }
		}
	}

	private func startPhoneMotion() {
		guard phoneMotionEnabled || gyroAimEnabled, motionManager.isDeviceMotionAvailable else { return }
		guard !motionManager.isDeviceMotionActive else { return }
		motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
		motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] data, _ in
			guard let self, let data else { return }
			self.phoneMotion(data)
		}
	}

	/// Interface orientation, cached on the main thread for the motion queue.
	var interfaceOrientation: UIInterfaceOrientation = .landscapeRight

	private func phoneMotion(_ m: CMDeviceMotion) {
		// Device axes: x right / y up in portrait, z out of the screen.
		// Map to the screen as held in landscape, which lines up with how a
		// DualSense's axes behave when the phone is upright in a clamp controller.
		let r = m.rotationRate
		let a = (x: m.gravity.x + m.userAcceleration.x, y: m.gravity.y + m.userAcceleration.y, z: m.gravity.z + m.userAcceleration.z)
		let gyro: SIMD3<Float>
		let accel: SIMD3<Float>
		switch interfaceOrientation {
		case .landscapeLeft:  // device top on the right
			gyro = SIMD3(Float(r.y), Float(-r.x), Float(r.z))
			accel = SIMD3(Float(a.y), Float(-a.x), Float(a.z))
		default:  // landscapeRight: device top on the left
			gyro = SIMD3(Float(-r.y), Float(r.x), Float(r.z))
			accel = SIMD3(Float(-a.y), Float(a.x), Float(a.z))
		}
		// CoreMotion reports gravity's direction; DualSense reports the reaction (+1 g up at rest)
		sendMotion(gyro: gyro, accel: -accel, timestamp: UInt32(truncatingIfNeeded: UInt64(m.timestamp * 1_000_000)))
	}

	private static func nowMicros() -> UInt32 {
		UInt32(truncatingIfNeeded: UInt64(CACurrentMediaTime() * 1_000_000))
	}
}
