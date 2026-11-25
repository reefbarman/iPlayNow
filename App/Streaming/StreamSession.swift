import AVFoundation
import Foundation
import NVSTKit
import Observation
import UIKit

struct StreamStats: Equatable {
	var fps: Double = 0
	var bitrateMbps: Double = 0
	var width: Int = 0
	var height: Int = 0
	var decodeMs: Double = 0
	var pingMs: Double = 0
	/// Packets lost in the last second, and since connecting
	var packetsLost = 0
	var totalPacketsLost = 0
	/// Share of video packets lost in the last second, 0...1
	var packetLoss: Double = 0
	/// Frames that never reached the screen since connecting
	var lostFrames = 0
	var controller: String?
	/// The screen's refresh rate, 0 if unknown
	var displayHz: Double = 0
	/// Frame generation is running (on, and the game's frame rate fits twice into the screen's)
	var frameGenActive = false
	/// Why frame generation is on in Settings but not running, e.g. "game at 90 fps, needs 60 or less"
	var frameGenOffReason: String?
	/// In-between frames made and skipped in the last second, and GPU ms per frame
	var generatedFPS = 0
	var skippedFrames = 0
	/// Repeated stream frames dropped in the last second (a 30 fps game in a 60 fps stream)
	var repeatedFrames = 0
	var generateMs: Double = 0
	/// Extra frame generation detail, e.g. a stepped-down quality level
	var frameGenStatus: String?
}

/// One play session: GeForce NOW launch (queue, rig setup) and then the NVST stream,
/// with the renderer, audio and controller input around it.
@MainActor @Observable
final class StreamSession {
	enum State: Equatable {
		/// Waiting on GeForce NOW: see `launch.phase`
		case launching
		case connecting
		case streaming
		/// The connection dropped: getting the same rig back. 1...maxReconnectAttempts.
		case reconnecting(attempt: Int)
		case ended(error: String?)
	}

	static let maxReconnectAttempts = 3

	private(set) var state: State = .launching
	/// The ended screen can offer Reconnect: the drop wasn't the game or GeForce NOW ending things
	private(set) var canReconnect = false
	private(set) var stats = StreamStats()
	/// Folded or backgrounded: video isn't drawn and audio is muted, the stream stays up
	private(set) var paused = false
	private(set) var settings: StreamSettings
	/// The mic is on for this stream: the rig accepted it and the phone is capturing
	private(set) var micActive = false
	private(set) var micMuted = false
	/// Check connection: running, or its verdict waiting to be read
	private(set) var connectionCheck: ConnectionCheck?
	private(set) var connectionCheckResult: ConnectionCheckResult?
	/// How each connection went, for Auto bitrate (one per connect, so a reconnect adds one)
	@ObservationIgnored private(set) var qualityReports: [StreamQualityReport] = []
	/// The bitrate the current connection started with (Play Again changes `streamSettings` first)
	@ObservationIgnored private var qualityBitrate = 0
	@ObservationIgnored private var qualityStreamingSeconds = 0
	@ObservationIgnored private var qualitySeconds = 0
	@ObservationIgnored private var qualityLossSum: Double = 0
	@ObservationIgnored private var qualityPeak: Double = 0
	@ObservationIgnored private var qualityLostAtStart = 0
	@ObservationIgnored private var qualityLost = 0

	let launch: GFNLaunch
	var game: GFNGame { launch.game }

	@ObservationIgnored let renderer: MetalRenderer?
	@ObservationIgnored let input = ControllerInput()
	@ObservationIgnored private let audio = AudioOutput()
	@ObservationIgnored private var stream: NVSTStream?
	/// The settings the stream was started with: its resolution, frame rate, bitrate, codec and HDR
	@ObservationIgnored private(set) var streamSettings: StreamSettings
	@ObservationIgnored private var physicalPad = NVSTGamepad()
	@ObservationIgnored private var virtualPad = VirtualPadState()
	@ObservationIgnored private var guideRelease: DispatchWorkItem?
	@ObservationIgnored private var gyroStick = GyroStick()
	/// Where gyro aiming is pushing the right stick, on top of the sticks themselves
	@ObservationIgnored private var gyroStickPosition = SIMD2<Float>.zero
	/// Mouse buttons the touchscreen is holding down, and the trackpad's sub-pixel leftovers
	@ObservationIgnored private var heldMouseButtons: Set<NVSTMouseButton> = []
	@ObservationIgnored private var mouseRemainder = CGVector.zero
	@ObservationIgnored private var lastStats: NVSTStats?
	@ObservationIgnored private var lastStatsTime: CFTimeInterval = 0
	@ObservationIgnored private var lastGenerated = 0
	@ObservationIgnored private var lastSkipped = 0
	@ObservationIgnored private var lastRepeated = 0
	@ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
	/// Bumped on every teardown, so late callbacks from an old stream are ignored
	@ObservationIgnored private var streamID = 0
	@ObservationIgnored private var reconnectWork: DispatchWorkItem?
	@ObservationIgnored private var reconnectAttempt = 0

	init(accounts: GFNAccountStore, game: GFNGame, variant: GFNGameVariant, settings: StreamSettings) {
		self.settings = settings
		self.streamSettings = settings
		launch = GFNLaunch(accounts: accounts, game: game, variant: variant, request: Self.request(for: settings))
		renderer = MetalRenderer()
		let center = NotificationCenter.default
		lifecycleObservers = [
			center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.releaseInput() }
			},
		]
		launch.onPhase = { [weak self] phase in self?.launchPhaseChanged(phase) }
	}

	private func launchPhaseChanged(_ phase: GFNLaunch.Phase) {
		switch phase {
		case .ready(let session):
			connect(session)
		case .failed(let message):
			// While launching, the launch card shows this itself
			if case .reconnecting = state { reconnectFailed(message) }
		default:
			break
		}
	}

	private static func request(for settings: StreamSettings) -> GFNStreamRequest {
		let size = settings.resolution.size
		return GFNStreamRequest(width: size.width, height: size.height, fps: settings.fps, hdr: settings.hdr)
	}

	/// The view calls stop() when it goes away; this just drops the observers
	deinit {
		lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
	}

	// MARK: - Lifecycle

	/// Asks GeForce NOW for a rig, then connects once it's ready
	func start() {
		guard renderer != nil else {
			state = .ended(error: "Metal isn't available on this device.")
			return
		}
		teardown()
		cancelReconnect()
		canReconnect = false
		state = .launching
		launch.start()
	}

	/// Ends the stream and the GeForce NOW session. Safe to call more than once.
	func stop() {
		teardown()
		cancelReconnect()
		canReconnect = false
		if case .ended = state {} else { state = .ended(error: nil) }
		let launch = launch
		Task { await launch.cancel() }
	}

	/// From the "ended" screen: a fresh launch with the latest settings
	func playAgain() {
		streamSettings = settings
		launch.setRequest(Self.request(for: settings))
		start()
	}

	private func connect(_ session: GFNSession) {
		guard stream == nil, let renderer else { return }
		// A reconnect keeps its own card up until the picture is back
		if case .reconnecting = state {} else { state = .connecting }
		streamID &+= 1
		let id = streamID
		let s = streamSettings
		let size = s.resolution.size
		let config = NVSTStreamConfig(
			sessionID: session.id, rtspsEndpoints: session.rtspsEndpoints,
			width: size.width, height: size.height, fps: s.fps,
			maxBitrateKbps: s.bitrateMbps * 1000, codec: s.effectiveCodec == .h265 ? .hevc : .h264, hdr: s.hdr,
			microphone: s.microphone && AVAudioApplication.shared.recordPermission == .granted)
		let stream = NVSTStream(config: config)
		self.stream = stream

		configureRenderer()
		renderer.resetSmoothing()
		renderer.setPaused(paused)
		lastGenerated = renderer.generatedFrames
		lastSkipped = renderer.skippedFrames
		lastRepeated = renderer.repeatedFrames
		lastStats = nil
		qualityBitrate = s.bitrateMbps
		qualityStreamingSeconds = 0
		qualitySeconds = 0
		qualityLossSum = 0
		qualityPeak = 0
		qualityLostAtStart = 0
		qualityLost = 0

		stream.onFrame = { [weak renderer] frame in renderer?.display(frame) }
		let feedback = input.feedback
		stream.onRumble = { low, high in feedback.rumble(low: low, high: high) }
		stream.onStats = { [weak self] stats in
			DispatchQueue.main.async { MainActor.assumeIsolated { self?.statsArrived(stats, id: id) } }
		}
		stream.onEnded = { [weak self] end in
			DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamEnded(end, id: id) } }
		}

		input.gyroAimEnabled = settings.gyroAim != .off
		input.feedback.rumbleEnabled = settings.rumble
		input.feedback.phoneHapticsScale = settings.phoneHaptics.scale
		input.feedback.controllerVibrationScale = settings.controllerVibration.scale
		input.feedback.controllerRumbleRate = settings.controllerRumbleRate
		input.onPad = { [weak self] pad in
			self?.physicalPad = pad
			self?.sendPad()
		}
		input.onGyroAim = { [weak self] gyro, ts in self?.gyroAimed(gyro: gyro, timestamp: ts) }
		input.start()

		Task { [weak self] in
			do {
				try await stream.start()
				guard let self, self.streamID == id else { return }
				if self.reconnectAttempt > 0 { log.notice("Reconnected after \(self.reconnectAttempt) attempt(s)") }
				self.reconnectAttempt = 0
				self.state = .streaming
				self.audio.start(stream: stream, mic: stream.config.microphone && stream.microphoneAvailable)
				self.audio.muted = self.paused
				self.applyMicState()
				self.sendPad()
				UIApplication.shared.isIdleTimerDisabled = true
			} catch {
				guard let self, self.streamID == id else { return }
				log.error("Stream start failed: \(error.localizedDescription, privacy: .public)")
				self.teardown()
				if case .reconnecting = self.state {
					self.reconnectFailed(error.localizedDescription)
					return
				}
				self.state = .ended(error: error.localizedDescription)
				await self.launch.end()
			}
		}
	}

	private func streamEnded(_ end: NVSTEnd, id: Int) {
		guard id == streamID else { return }
		log.notice("Stream ended: \(String(describing: end), privacy: .public)")
		let wasPlaying = state == .streaming
		teardown()
		switch end {
		case .failed(let reason) where wasPlaying:
			// The connection dropped, not the game: the rig is probably still there
			beginReconnect(reason: reason)
		case .paused:
			// GeForce NOW holds the rig for a while; the player can pick it back up
			canReconnect = launch.canRejoin
			state = .ended(error: end.message)
		default:
			state = .ended(error: end.message)
			let launch = launch
			Task { await launch.end() }
		}
	}

	// MARK: - Reconnect

	/// From the ended screen: try to get the same rig back
	func reconnect() {
		guard case .ended = state, canReconnect else { return }
		cancelReconnect()
		canReconnect = false
		reconnectAttempt = 1
		state = .reconnecting(attempt: 1)
		launch.rejoin()
	}

	private func beginReconnect(reason: String) {
		cancelReconnect()
		log.notice("Connection lost (\(reason, privacy: .public)), reconnecting")
		reconnectAttempt = 1
		state = .reconnecting(attempt: 1)
		scheduleRejoin(after: 1)
	}

	/// A reconnect attempt didn't work: wait longer and try again, or give up
	private func reconnectFailed(_ message: String) {
		guard case .reconnecting = state else { return }
		log.notice("Reconnect attempt \(self.reconnectAttempt) failed: \(message, privacy: .public)")
		guard reconnectAttempt < Self.maxReconnectAttempts, launch.canRejoin else {
			reconnectAttempt = 0
			// Leaving the screen ends the session, so it's safe to keep it for a manual retry
			canReconnect = launch.canRejoin
			state = .ended(error: canReconnect
				? "Couldn't reconnect to \(game.title). Check your connection, then try again."
				: message)
			return
		}
		reconnectAttempt += 1
		state = .reconnecting(attempt: reconnectAttempt)
		// 1 s, 2 s, 4 s
		scheduleRejoin(after: pow(2, Double(reconnectAttempt - 1)))
	}

	private func scheduleRejoin(after delay: Double) {
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				guard let self, case .reconnecting = self.state else { return }
				self.reconnectWork = nil
				self.launch.rejoin()
			}
		}
		reconnectWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}

	private func cancelReconnect() {
		reconnectWork?.cancel()
		reconnectWork = nil
		reconnectAttempt = 0
	}

	private func teardown() {
		finishQualityReport()
		// A new connection starts fresh counters, so a check in progress can't carry on
		connectionCheck = nil
		streamID &+= 1
		input.stop()
		physicalPad = NVSTGamepad()
		virtualPad = VirtualPadState()
		gyroStickPosition = .zero
		gyroStick.reset()
		guideRelease?.cancel()
		guideRelease = nil
		heldMouseButtons.removeAll()
		mouseRemainder = .zero
		micActive = false
		audio.stop()
		stream?.stop()
		stream = nil
		input.feedback.reset()
		UIApplication.shared.isIdleTimerDisabled = false
	}

	// MARK: - Settings

	/// Applies new settings. Resolution, frame rate, bitrate and codec are fixed for a session
	/// (the stream menu doesn't offer them), so those keep coming from `streamSettings`.
	func apply(_ new: StreamSettings) {
		settings = new
		input.gyroAimEnabled = new.gyroAim != .off
		if new.gyroAim == .off, gyroStickPosition != .zero {
			gyroStickPosition = .zero
			sendPad()
		}
		input.feedback.rumbleEnabled = new.rumble
		input.feedback.phoneHapticsScale = new.phoneHaptics.scale
		input.feedback.controllerVibrationScale = new.controllerVibration.scale
		input.feedback.controllerRumbleRate = new.controllerRumbleRate
		renderer?.setDisplayMode(new.displayMode)
		configureRenderer()
	}

	private var screenHz: Int {
		settings.highRefreshDisplay ? UIScreen.main.maximumFramesPerSecond : 60
	}

	/// The renderer decides when frame generation runs, from the game's measured frame rate:
	/// a 60 fps game in a 120 fps stream still gets it on a 120 Hz screen
	private func configureRenderer() {
		renderer?.configure(
			hdr: streamSettings.hdr, displayMode: settings.displayMode, upscaling: settings.upscaling,
			frameGeneration: settings.frameGeneration, fps: streamSettings.fps,
			frameCapture: false, smoothing: false, screenHz: screenHz)
	}

	/// Plain words for why frame generation isn't running
	private func frameGenOffReason(gameFPS: Double) -> String {
		guard gameFPS > 0 else { return "measuring" }
		let canDouble = gameFPS <= Double(UIScreen.main.maximumFramesPerSecond) / 2 * 1.05
		if !settings.highRefreshDisplay, UIScreen.main.maximumFramesPerSecond > 60, canDouble {
			return "turn on 120 Hz screen"
		}
		return "game at \(Int(gameFPS.rounded())) fps, needs \(screenHz / 2) or less"
	}

	func setPaused(_ paused: Bool) {
		guard paused != self.paused else { return }
		self.paused = paused
		renderer?.setPaused(paused)
		audio.muted = paused
		applyMicState()
		if paused {
			releaseInput()
		} else {
			// We dropped frames while paused, so get a clean keyframe
			stream?.requestKeyframe()
		}
	}

	/// Lets go of every button and stick, so nothing stays held in the game
	/// while we can't see the controller (iOS doesn't send controller input to background apps)
	private func releaseInput() {
		physicalPad = NVSTGamepad()
		gyroStickPosition = .zero
		resetScreenInput()
		sendPad()
	}

	// MARK: - Input (main thread)

	/// The stream menu is open: the controller drives the menu, so the game sees nothing held
	private var inputHeld = false

	func setInputHeld(_ held: Bool) {
		guard held != inputHeld else { return }
		inputHeld = held
		if held { releaseInput() }
	}

	/// The Controller Test is open over the stream menu: let go of the controller so the test
	/// can read it, and pick it up again when it closes
	func lendController(_ lend: Bool) {
		if lend {
			releaseInput()
			input.suspend()
		} else if stream != nil {
			input.start()
		}
	}

	private func sendPad() {
		guard let stream else { return }
		guard !inputHeld else {
			stream.send(NVSTGamepad())
			return
		}
		var pad = physicalPad
		pad.buttons |= virtualPad.buttons
		if guideRelease != nil { pad.buttons |= NVSTGamepad.guide }
		pad.leftTrigger = max(pad.leftTrigger, virtualPad.leftTrigger)
		pad.rightTrigger = max(pad.rightTrigger, virtualPad.rightTrigger)
		if let stick = virtualPad.leftStick { (pad.leftX, pad.leftY) = (stick.x, stick.y) }
		if let stick = virtualPad.rightStick { (pad.rightX, pad.rightY) = (stick.x, stick.y) }
		if gyroStickPosition != .zero {
			pad.rightX = Int16(clamping: Int(pad.rightX) + Int((gyroStickPosition.x * 32767).rounded()))
			pad.rightY = Int16(clamping: Int(pad.rightY) + Int((gyroStickPosition.y * 32767).rounded()))
		}
		stream.send(pad)
	}

	private func gyroAimed(gyro: SIMD3<Float>, timestamp: UInt32) {
		gyroStick.sensitivity = Float(settings.gyroAimSensitivity)
		gyroStick.invertY = settings.gyroAimInvertY
		gyroStick.turning = settings.gyroAimTurning
		gyroStick.verticalScale = Float(settings.gyroAimVerticalScale)
		gyroStick.deadzone = Float(settings.gyroAimDeadzone)
		gyroStick.responseCurve = Float(settings.gyroAimResponseCurve)
		gyroStick.perAxisDeadzone = settings.gyroAimPerAxisDeadzone
		// Keeps smoothing while the hold button is up
		let position = gyroStick.update(gyro: gyro, timestamp: timestamp)
		let next = gyroAimHeld ? position : .zero
		guard next != gyroStickPosition else { return }
		gyroStickPosition = next
		sendPad()
	}

	/// The button for gyro aiming is down, if it needs one. The game still gets the button.
	private var gyroAimHeld: Bool {
		switch settings.gyroAim {
		case .off: false
		case .always: true
		case .holdingLT: max(physicalPad.leftTrigger, virtualPad.leftTrigger) > 30
		case .holdingRB: (physicalPad.buttons | virtualPad.buttons) & NVSTGamepad.rightShoulder != 0
		}
	}

	func setVirtualPad(_ pad: VirtualPadState) {
		virtualPad = pad
		sendPad()
	}

	func resetScreenInput() {
		let hadButtons = virtualPad != VirtualPadState() || guideRelease != nil
		virtualPad = VirtualPadState()
		guideRelease?.cancel()
		guideRelease = nil
		if hadButtons { sendPad() }
		for button in heldMouseButtons { stream?.sendMouseButton(button, pressed: false) }
		heldMouseButtons.removeAll()
		mouseRemainder = .zero
	}

	// MARK: - Microphone

	func toggleMicMuted() {
		micMuted.toggle()
		applyMicState()
	}

	/// Sends mic audio while streaming, unmuted and not paused
	private func applyMicState() {
		micActive = state == .streaming && stream != nil && audio.micEnabled
		let live = micActive && !micMuted && !paused
		audio.micLive = live
		stream?.setMicrophoneLive(live)
	}

	/// Typed on the iPhone keyboard: sent as it's typed, so it works in any text box
	func typeText(_ text: String) {
		guard let stream, !inputHeld else { return }
		stream.sendText(text)
	}

	func pressKey(_ key: StreamKey) {
		guard let stream, !inputHeld else { return }
		stream.sendKey(virtualKey: key.rawValue)
	}

	/// The touchscreen as a mouse. Positions are in the stream's own resolution.
	func sendMouse(_ event: TouchMouse.Event) {
		guard let stream, !inputHeld else { return }
		let size = streamSettings.resolution.size
		switch event {
		case .move(let point):
			stream.sendMouseMove(x: Int((point.x * CGFloat(size.width)).rounded()),
				y: Int((point.y * CGFloat(size.height)).rounded()), width: size.width, height: size.height)
		case .moveBy(let fraction):
			mouseRemainder.dx += fraction.dx * CGFloat(size.width)
			mouseRemainder.dy += fraction.dy * CGFloat(size.height)
			let dx = mouseRemainder.dx.rounded(.towardZero), dy = mouseRemainder.dy.rounded(.towardZero)
			guard dx != 0 || dy != 0 else { return }
			mouseRemainder.dx -= dx
			mouseRemainder.dy -= dy
			stream.sendMouseMove(dx: Int(dx), dy: Int(dy))
		case .button(let button, let pressed):
			if pressed { heldMouseButtons.insert(button) } else { heldMouseButtons.remove(button) }
			stream.sendMouseButton(button, pressed: pressed)
		case .wheel(let delta):
			stream.sendMouseWheel(delta)
		}
	}

	/// On-screen Xbox button, for controllers whose home button iOS keeps for itself
	func pressGuideButton() {
		guideRelease?.cancel()
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				self?.guideRelease = nil
				self?.sendPad()
			}
		}
		guideRelease = work
		sendPad()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
	}

	// MARK: - Stats

	private func statsArrived(_ n: NVSTStats, id: Int) {
		guard id == streamID else { return }
		let now = CACurrentMediaTime()
		defer {
			lastStats = n
			lastStatsTime = now
		}
		guard let last = lastStats else { return }
		let seconds = max(0.25, now - lastStatsTime)
		var s = StreamStats()
		s.fps = Double(n.framesDecoded - last.framesDecoded) / seconds
		s.bitrateMbps = Double(n.bytesReceived - last.bytesReceived) * 8 / seconds / 1_000_000
		s.width = n.width
		s.height = n.height
		s.decodeMs = n.decodeMs
		s.pingMs = n.pingMs
		s.packetsLost = max(0, n.packetsLost - last.packetsLost)
		s.totalPacketsLost = n.packetsLost
		let received = max(0, n.packetsReceived - last.packetsReceived)
		s.packetLoss = received + s.packetsLost > 0 ? Double(s.packetsLost) / Double(received + s.packetsLost) : 0
		s.lostFrames = n.framesLost
		s.controller = input.controllerName
		if let renderer {
			s.displayHz = renderer.displayHz
			s.frameGenActive = settings.frameGeneration && renderer.frameGenRunning
			if settings.frameGeneration, !s.frameGenActive {
				s.frameGenOffReason = frameGenOffReason(gameFPS: renderer.gameFPS)
			}
			s.generatedFPS = renderer.generatedFrames - lastGenerated
			s.skippedFrames = renderer.skippedFrames - lastSkipped
			s.repeatedFrames = renderer.repeatedFrames - lastRepeated
			s.generateMs = renderer.generateMs
			s.frameGenStatus = renderer.frameGenStatus
			lastGenerated = renderer.generatedFrames
			lastSkipped = renderer.skippedFrames
			lastRepeated = renderer.repeatedFrames
		}
		stats = s
		sampleQuality(s)
		sampleConnectionCheck(s)
	}

	// MARK: - Check connection

	/// Watches the next few seconds of the stream, then suggests a bitrate for next time
	func startConnectionCheck() {
		guard state == .streaming else { return }
		connectionCheckResult = nil
		connectionCheck = ConnectionCheck()
	}

	func dismissConnectionCheck() {
		connectionCheck = nil
		connectionCheckResult = nil
	}

	private func sampleConnectionCheck(_ stats: StreamStats) {
		// Paused (folded, another app) or mid-reconnect: nothing useful to measure
		guard var check = connectionCheck, state == .streaming, !paused else { return }
		check.add(stats)
		if check.isComplete {
			let result = check.result(requested: streamSettings.bitrateMbps)
			log.notice("Connection check: \(result.title, privacy: .public). \(result.detail, privacy: .public)")
			connectionCheck = nil
			connectionCheckResult = result
		} else {
			connectionCheck = check
		}
	}

	// MARK: - Auto bitrate

	/// Seconds after connecting that are left out: the start can be rough on any network
	private static let qualityWarmupSeconds = 5

	private func sampleQuality(_ s: StreamStats) {
		guard state == .streaming, !paused else { return }
		qualityStreamingSeconds += 1
		if qualityStreamingSeconds == Self.qualityWarmupSeconds { qualityLostAtStart = s.lostFrames }
		guard qualityStreamingSeconds > Self.qualityWarmupSeconds else { return }
		qualitySeconds += 1
		qualityLossSum += s.packetLoss
		qualityPeak = max(qualityPeak, s.bitrateMbps)
		qualityLost = s.lostFrames
	}

	private func finishQualityReport() {
		guard qualitySeconds > 0 else { return }
		qualityReports.append(StreamQualityReport(
			bitrateMbps: qualityBitrate, seconds: qualitySeconds,
			averageLoss: qualityLossSum / Double(qualitySeconds),
			lostFrames: max(0, qualityLost - qualityLostAtStart), peakMbps: qualityPeak))
		qualitySeconds = 0
	}
}
