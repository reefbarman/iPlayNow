import GameController
import SwiftUI

/// Lets a game controller drive app screens outside the stream: the d-pad or
/// left stick moves a selection, the bottom face button (A, or ✕ on PlayStation
/// pads) confirms and the right one (B / ○) cancels.
///
/// Uses per-element handlers so it never touches the gamepad-wide
/// `valueChangedHandler` that `ControllerInput` owns while streaming, and
/// detaches entirely whenever its screen is covered or busy.
@Observable
final class ListGamepadNavigator {
	@ObservationIgnored var onMove: ((Int) -> Void)?
	@ObservationIgnored var onConfirm: (() -> Void)?
	@ObservationIgnored var onCancel: (() -> Void)?
	/// SF Symbol for the connected controller's confirm button, nil without a controller
	private(set) var confirmSymbol: String?
	/// SF Symbol for the connected controller's cancel button, nil without a controller
	private(set) var cancelSymbol: String?

	/// The navigator whose handlers are on the controller. Only one screen drives it
	/// at a time, and a screen going away mustn't clear handlers the next one set.
	private static weak var owner: ListGamepadNavigator?

	@ObservationIgnored private var controller: GCController?
	@ObservationIgnored private var observers: [NSObjectProtocol] = []
	@ObservationIgnored private var active = false
	@ObservationIgnored private var confirmArmed = false
	@ObservationIgnored private var cancelArmed = false
	@ObservationIgnored private var direction = 0
	@ObservationIgnored private var repeatTimer: Timer?

	func start() {
		guard observers.isEmpty else { return }
		for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent] {
			observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				self?.refresh()
			})
		}
		refresh()
	}

	func stop() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers.removeAll()
		detach()
		confirmSymbol = nil
		cancelSymbol = nil
	}

	func setActive(_ active: Bool) {
		self.active = active
		refresh()
	}

	private func refresh() {
		let candidates = GCController.controllers().filter { $0.extendedGamepad != nil }
		let next = GCController.current.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
		confirmSymbol = next.map(Self.confirmSymbol(for:))
		cancelSymbol = next.map(Self.cancelSymbol(for:))

		let wanted = active ? next : nil
		guard wanted !== controller || (wanted != nil && Self.owner !== self) else { return }
		detach()
		guard let wanted, let pad = wanted.extendedGamepad else { return }
		controller = wanted
		Self.owner = self
		pad.dpad.valueChangedHandler = { [weak self] _, _, _ in self?.updateDirection(pad) }
		pad.leftThumbstick.valueChangedHandler = { [weak self] _, _, _ in self?.updateDirection(pad) }
		pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
			guard let self else { return }
			// Fire on release so the press doesn't carry into the stream
			if pressed {
				self.confirmArmed = true
			} else if self.confirmArmed {
				self.confirmArmed = false
				self.onConfirm?()
			}
		}
		pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
			guard let self else { return }
			if pressed {
				self.cancelArmed = true
			} else if self.cancelArmed {
				self.cancelArmed = false
				self.onCancel?()
			}
		}
	}

	/// The controller's own symbol for its confirm button when the system can render it
	private static func confirmSymbol(for controller: GCController) -> String {
		if let name = controller.extendedGamepad?.buttonA.sfSymbolsName, UIImage(systemName: name) != nil {
			return name
		}
		let pad = controller.extendedGamepad
		return pad is GCDualSenseGamepad || pad is GCDualShockGamepad ? "xmark.circle" : "a.circle"
	}

	private static func cancelSymbol(for controller: GCController) -> String {
		if let name = controller.extendedGamepad?.buttonB.sfSymbolsName, UIImage(systemName: name) != nil {
			return name
		}
		let pad = controller.extendedGamepad
		return pad is GCDualSenseGamepad || pad is GCDualShockGamepad ? "circle.circle" : "b.circle"
	}

	private func detach() {
		if Self.owner === self, let pad = controller?.extendedGamepad {
			pad.dpad.valueChangedHandler = nil
			pad.leftThumbstick.valueChangedHandler = nil
			pad.buttonA.pressedChangedHandler = nil
			pad.buttonB.pressedChangedHandler = nil
			Self.owner = nil
		}
		controller = nil
		confirmArmed = false
		cancelArmed = false
		setDirection(0)
	}

	private func updateDirection(_ pad: GCExtendedGamepad) {
		let y = pad.leftThumbstick.yAxis.value
		if pad.dpad.up.isPressed || y > 0.6 {
			setDirection(-1)
		} else if pad.dpad.down.isPressed || y < -0.6 {
			setDirection(1)
		} else if abs(y) < 0.4 {
			setDirection(0)
		}
	}

	/// Moves once, then repeats while held
	private func setDirection(_ dir: Int) {
		guard dir != direction else { return }
		direction = dir
		repeatTimer?.invalidate()
		repeatTimer = nil
		guard dir != 0 else { return }
		onMove?(dir)
		repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
			self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
				guard let self, self.direction != 0 else { return }
				self.onMove?(self.direction)
			}
		}
	}
}
