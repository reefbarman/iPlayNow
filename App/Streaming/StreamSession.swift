import ChiakiKit
import Foundation
import Observation
import UIKit

struct StreamStats: Equatable {
	var fps: Double = 0
	var bitrateMbps: Double = 0
	var width: Int32 = 0
	var height: Int32 = 0
	var decodeMs: Double = 0
	/// Round trip measured while connecting
	var rttMs: Double = 0
	/// Packets lost recently, 0...1
	var packetLoss: Double = 0
	/// Takion protocol version in use (12, or 20 with the experimental mode), 0 if unknown
	var takionVersion = 0
	var failedFrames = 0
	var lostFrames = 0
	var hdrFrames = false
	var controller: String?
	/// The screen's refresh rate, 0 if unknown
	var displayHz: Double = 0
	/// Frame generation is running (on, and the screen is fast enough)
	var frameGenActive = false
	/// In-between frames made and skipped in the last second, and GPU ms per frame
	var generatedFPS = 0
	var skippedFrames = 0
	/// Repeated stream frames dropped in the last second (a 30 fps game in a 60 fps stream)
	var repeatedFrames = 0
	var generateMs: Double = 0
	/// Extra frame generation detail, e.g. a stepped-down quality level
	var frameGenStatus: String?
	/// Network smoothing (nil when off): late packets, freezes ridden through, etc.
	var smoothing: SmoothingStats?
}

/// Network smoothing counters. Totals since connecting, except the current wait and depth.
struct SmoothingStats: Equatable {
	/// Video packets that turned up after we'd stopped waiting, and ones given up on
	var packetsLate = 0
	var packetsSkipped = 0
	/// Current wait for a missing video packet
	var waitMs: Double = 0
	/// Frames error correction couldn't rebuild (each would have frozen the picture without smoothing)
	var fecFailures = 0
	/// Frames decoded against an older frame because theirs was lost
	var framesPatched = 0
	/// Frames held back right now, dropped to keep the delay bounded, and times the buffer ran dry
	var heldFrames = 0
	var droppedFrames = 0
	var underruns = 0
}

/// One Remote Play connection: chiaki session + decoder + renderer + audio + input.
@Observable
final class StreamSession {
	enum State: Equatable {
		case idle
		case connecting
		case streaming
		case needsPIN(incorrect: Bool)
		/// The connection dropped and we're trying again
		case reconnecting(attempt: Int)
		/// Settings changed that need a new connection. Retries until it connects or is cancelled.
		case applyingSettings(attempt: Int)
		/// We asked the console to go to rest mode and the connection is closed
		case consoleAsleep
		case ended(error: String?)
	}

	static let maxReconnectAttempts = 3
	/// After a settings change the PS5 takes a while to let go of the old connection,
	/// so wait before the first attempt and between retries
	private static let settingsRetryDelay: Double = 5
	/// How long to wait for the console to close the connection after a rest mode request
	private static let sleepTimeout: Double = 5

	private(set) var state: State = .idle
	private(set) var stats = StreamStats()
	/// A text box is open on the PS5: the text it started with. nil when there's none.
	private(set) var keyboardText: String?
	/// Folded or backgrounded: video isn't drawn and audio is muted, connection stays up
	private(set) var paused = false
	/// Debug frame capture: saving, saved or failed (shown by the capture button)
	private(set) var captureStatus: String?
	/// Asked the console to go to rest mode, waiting for it to close the connection
	private(set) var goingToSleep = false
	/// A short message for the user, e.g. a rest mode request that failed
	private(set) var notice: String?
	/// "Optimise connection" while it's watching the stream, and what it found
	private(set) var connectionCheck: ConnectionCheck?
	private(set) var connectionCheckResult: ConnectionCheckResult?
	/// Streaming with the mic on (setting on and permission granted)
	private(set) var micActive = false
	/// The user muted the mic. Kept across reconnects.
	private(set) var micMuted = false

	/// Refreshed from `latestConsole` on every connect, so retries follow an IP change
	private(set) var console: Console
	private(set) var settings: StreamSettings
	/// The console as currently stored (discovery updates its address when it moves).
	/// Without this, Reconnect would keep dialling the address the stream screen opened with.
	@ObservationIgnored var latestConsole: (() -> Console?)?

	@ObservationIgnored let renderer: MetalRenderer?
	@ObservationIgnored let input = ControllerInput()
	@ObservationIgnored private let audio = AudioOutput()
	@ObservationIgnored private var decoder: VideoDecoder?
	@ObservationIgnored private var handle: OpaquePointer?
	@ObservationIgnored private var connectionRef: Unmanaged<Connection>?
	/// Bumped on every teardown, so late events from an old connection are ignored
	@ObservationIgnored private var connectionID = 0
	@ObservationIgnored private var statsTimer: Timer?
	@ObservationIgnored private var lastDecoded = 0
	@ObservationIgnored private var lastGenerated = 0
	@ObservationIgnored private var lastSkipped = 0
	@ObservationIgnored private var lastRepeated = 0
	@ObservationIgnored private var lostFrames: Int32 = 0
	@ObservationIgnored private var touchIDs: [Int: Int32] = [:]
	@ObservationIgnored private var physicalPad = CKPadState()
	@ObservationIgnored private var virtualPad = VirtualPadState()
	@ObservationIgnored private var gyroStick = GyroStick()
	/// Where gyro aiming is pushing the right stick, on top of the sticks themselves
	@ObservationIgnored private var gyroStickPosition = SIMD2<Float>.zero
	@ObservationIgnored private var touchpadClicks: [Int: DispatchWorkItem] = [:]
	@ObservationIgnored private var psRelease: DispatchWorkItem?
	@ObservationIgnored private var reconnectAttempt = 0
	@ObservationIgnored private var reconnectWork: DispatchWorkItem?
	@ObservationIgnored private var sleepWork: DispatchWorkItem?
	@ObservationIgnored private var noticeWork: DispatchWorkItem?
	/// In another app: the connection is kept up for as long as iOS lets us run,
	/// but there's no decoding (VideoToolbox can't decode in the background).
	/// Read from the video thread.
	@ObservationIgnored private var backgrounded = false
	@ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
	/// We disconnected (or held off a reconnect) while in the background: connect again on return
	@ObservationIgnored private var resumeInForeground = false
	@ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
	/// How each finished connection went, for Auto bitrate (read once the screen closes)
	@ObservationIgnored private(set) var qualityReports: [StreamQualityReport] = []
	@ObservationIgnored private var qualityBitrate = 0
	@ObservationIgnored private var qualityStreamingSeconds = 0
	@ObservationIgnored private var qualitySeconds = 0
	@ObservationIgnored private var qualityLossSum: Double = 0
	@ObservationIgnored private var qualityPeak: Double = 0
	@ObservationIgnored private var qualityLostAtStart = 0
	/// What we last told the console about the mic: live or muted. nil until we've said anything.
	@ObservationIgnored private var micConsoleLive: Bool?

	/// What chiaki's callbacks point at: this session plus which connection they belong to.
	/// Tearing a connection down makes chiaki send a "stopped" event that reaches the main
	/// thread later, and it must not end the connection that replaced it.
	private final class Connection {
		let session: StreamSession
		let id: Int
		init(session: StreamSession, id: Int) {
			self.session = session
			self.id = id
		}
	}

	init(console: Console, settings: StreamSettings) {
		self.console = console
		self.settings = settings
		self.renderer = MetalRenderer()
		backgrounded = UIApplication.shared.applicationState == .background
		let center = NotificationCenter.default
		lifecycleObservers = [
			center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
				self?.enterBackground()
			},
			center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
				self?.enterForeground()
			},
		]
	}

	deinit {
		lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
		teardown()
		endBackgroundTask()
	}

	// MARK: - Lifecycle

	func start() {
		guard handle == nil else { return }
		// A reconnect that came due while the user is in another app waits for them to come back
		if backgrounded {
			resumeInForeground = true
			return
		}
		guard let renderer else {
			state = .ended(error: "Metal isn't available on this device.")
			return
		}
		switch state {
		case .reconnecting, .applyingSettings: break
		default: state = .connecting
		}
		keyboardText = nil
		lostFrames = 0
		lastDecoded = 0
		qualityBitrate = settings.bitrateMbps
		qualityStreamingSeconds = 0
		qualitySeconds = 0
		qualityLossSum = 0
		qualityPeak = 0
		qualityLostAtStart = 0
		if let latest = latestConsole?(), latest.id == console.id {
			if latest.host != console.host { log.notice("Console address changed since the stream screen opened, using the new one") }
			console = latest
		}

		let codec = settings.effectiveCodec
		let decoder = VideoDecoder(hevc: codec == .h265, tenBit: settings.hdr)
		decoder.onFrame = { [weak renderer] frame in renderer?.display(frame) }
		self.decoder = decoder
		configureRenderer()
		renderer.resetSmoothing()
		renderer.setPaused(paused)
		lastGenerated = renderer.generatedFrames
		lastSkipped = renderer.skippedFrames
		lastRepeated = renderer.repeatedFrames

		var config = CKSessionConfig()
		let size = settings.resolution.size
		config.ps5 = console.ps5
		config.width = size.width
		config.height = size.height
		config.max_fps = UInt32(settings.fps)
		config.bitrate_kbps = UInt32(settings.bitrateMbps * 1000)
		config.codec = settings.hdr ? CK_CODEC_H265_HDR : (codec == .h265 ? CK_CODEC_H265 : CK_CODEC_H264)
		// Always advertise a DualSense: the PS5 then sends haptics/trigger data, and
		// for other controllers the haptics are converted to rumble.
		config.enable_dualsense = true
		config.enable_keyboard = true
		config.packet_loss_max = 0.05
		config.verbose_log = false
		config.enable_takion_v20 = settings.takionV20
		config.network_smoothing = settings.networkSmoothing
		withUnsafeMutableBytes(of: &config.regist_key) { _ = console.registKey.prefix(16).copyBytes(to: $0) }
		withUnsafeMutableBytes(of: &config.rp_key) { _ = console.rpKey.prefix(16).copyBytes(to: $0) }

		let ref = Unmanaged.passRetained(Connection(session: self, id: connectionID))
		connectionRef = ref
		var callbacks = CKSessionCallbacks()
		callbacks.user = ref.toOpaque()
		callbacks.on_video = { user, buf, size, lost, _ in
			guard let user, let buf else { return true }
			return Unmanaged<Connection>.fromOpaque(user).takeUnretainedValue().session.handleVideo(buf, Int(size), lost)
		}
		callbacks.on_event = { user, type, code, message in
			guard let user else { return }
			let connection = Unmanaged<Connection>.fromOpaque(user).takeUnretainedValue()
			let text = message.map { String(cString: $0) }
			DispatchQueue.main.async {
				connection.session.handleEvent(type, code: code, message: text, connection: connection.id)
			}
		}
		callbacks.on_rumble = { user, left, right in
			guard let user else { return }
			Unmanaged<Connection>.fromOpaque(user).takeUnretainedValue().session.input.feedback.rumble(left: left, right: right)
		}
		callbacks.on_trigger_effects = { user, tl, l, tr, r in
			guard let user, let l, let r else { return }
			let left = TriggerEffect(type: tl, data: Array(UnsafeBufferPointer(start: l, count: 10)))
			let right = TriggerEffect(type: tr, data: Array(UnsafeBufferPointer(start: r, count: 10)))
			let connection = Unmanaged<Connection>.fromOpaque(user).takeUnretainedValue()
			DispatchQueue.main.async {
				guard connection.id == connection.session.connectionID else { return }
				connection.session.input.feedback.setTriggerEffects(left: left, right: right)
			}
		}
		callbacks.on_haptics = { user, samples, frames in
			guard let user, let samples else { return }
			Unmanaged<Connection>.fromOpaque(user).takeUnretainedValue().session.input.feedback.haptics(samples, frames: Int(frames))
		}
		callbacks.on_pad_info = { user, type, a, b, c in
			guard let user else { return }
			let connection = Unmanaged<Connection>.fromOpaque(user).takeUnretainedValue()
			DispatchQueue.main.async {
				guard connection.id == connection.session.connectionID else { return }
				connection.session.input.feedback.padInfo(type, a, b, c)
			}
		}
		callbacks.on_log = { _, level, message in
			guard let message else { return }
			let text = String(cString: message)
			if level & 1 != 0 { chiakiLog.error("\(text, privacy: .public)") } else { chiakiLog.info("\(text, privacy: .public)") }
		}

		let created: OpaquePointer? = console.host.withCString { host in
			config.host = host
			return ck_session_create(&config, &callbacks)
		}
		guard let created else {
			ref.release()
			connectionRef = nil
			state = .ended(error: "Couldn't create the Remote Play session.")
			return
		}
		handle = created

		input.selectIsTouchpad = settings.selectIsTouchpad
		input.phoneMotionEnabled = settings.phoneMotion
		input.gyroAimEnabled = settings.gyroAim != .off
		input.feedback.rumbleEnabled = settings.rumble
		input.feedback.phoneHapticsScale = settings.phoneHaptics.scale
		input.onPad = { [weak self] pad in
			self?.physicalPad = pad
			self?.sendPad()
		}
		input.onMotion = { [weak self] gyro, accel, ts in
			guard let handle = self?.handle else { return }
			ck_session_set_motion(handle, gyro.x, gyro.y, gyro.z, accel.x, accel.y, accel.z, ts)
		}
		input.onTouch = { [weak self] event in self?.handleTouch(event) }
		input.onGyroAim = { [weak self] gyro, ts in self?.gyroAimed(gyro: gyro, timestamp: ts) }
		if !controllerLent { input.start() }

		audio.start(session: created, mic: settings.microphone)
		audio.muted = paused
		micConsoleLive = nil
		applyMicState()

		let err = ck_session_start(created)
		if err != 0 {
			teardown()
			state = .ended(error: "Couldn't start the session (error \(err)).")
			return
		}
		UIApplication.shared.isIdleTimerDisabled = true
		statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStats() }
	}

	/// Stops streaming and frees everything. Safe to call more than once.
	func stop() {
		cancelReconnect()
		sleepWork?.cancel()
		sleepWork = nil
		goingToSleep = false
		resumeInForeground = false
		teardown()
		endBackgroundTask()
		switch state {
		case .ended, .consoleAsleep: break
		default: state = .ended(error: nil)
		}
	}

	/// Manual reconnect from the "Disconnected" screen
	func reconnect() {
		cancelReconnect()
		start()
	}

	// MARK: - Background (main thread)

	/// Switching apps briefly shouldn't cost the connection. iOS gives a backgrounded app
	/// about 30 seconds: the connection stays up for that long, so coming back is instant.
	/// If it runs out we disconnect cleanly (so the console lets go of us) and reconnect on return.
	private func enterBackground() {
		backgrounded = true
		releaseInput()
		guard handle != nil, backgroundTask == .invalid else { return }
		backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Keep the stream connected") { [weak self] in
			self?.backgroundTimeExpired()
		}
		log.notice("In the background, keeping the stream connected")
	}

	private func enterForeground() {
		backgrounded = false
		endBackgroundTask()
		if resumeInForeground {
			resumeInForeground = false
			log.notice("Back from the background, reconnecting")
			start()
		}
		// Otherwise the connection is still up: unpausing (from the view) asks for a fresh keyframe
	}

	private func backgroundTimeExpired() {
		if handle != nil, !goingToSleep {
			log.notice("Background time ran out, disconnecting until the app returns")
			let wasPlaying: Bool
			switch state {
			case .streaming, .reconnecting: wasPlaying = true
			default: wasPlaying = false
			}
			teardown()
			resumeInForeground = true
			if wasPlaying {
				reconnectAttempt = 1
				state = .reconnecting(attempt: 1)
			}
		}
		endBackgroundTask()
	}

	private func endBackgroundTask() {
		guard backgroundTask != .invalid else { return }
		UIApplication.shared.endBackgroundTask(backgroundTask)
		backgroundTask = .invalid
	}

	/// The controller test screen has the controller: the console sees it let go,
	/// and its rumble, haptics, lightbar and trigger effects don't reach it
	@ObservationIgnored private var controllerLent = false

	/// Hands the controller to the controller test screen and takes it back
	func lendController(_ lent: Bool) {
		guard lent != controllerLent else { return }
		controllerLent = lent
		if lent {
			input.suspend()
			physicalPad = CKPadState()
			gyroStickPosition = .zero
			gyroStick.reset()
			sendPad()
		} else if handle != nil {
			input.start()
		}
	}

	/// Lets go of every button, stick and touch, so nothing stays held on the console
	/// while we can't see the controller (iOS doesn't send controller input to background apps)
	private func releaseInput() {
		physicalPad = CKPadState()
		gyroStickPosition = .zero
		resetScreenInput()
		for slot in touchIDs.keys { handleTouch(.up(slot: slot)) }
		sendPad()
	}

	private func cancelReconnect() {
		reconnectWork?.cancel()
		reconnectWork = nil
		reconnectAttempt = 0
	}

	/// Drops that are worth retrying: the network went away or the connection
	/// broke, as opposed to e.g. the console being in use or refusing us.
	private static func isRetryable(quitReason code: Int32) -> Bool {
		switch code {
		case 2, 7, 8, 10, 11: true  // SESSION_REQUEST_UNKNOWN, CTRL_UNKNOWN, CTRL_CONNECT_FAILED, STREAM_CONNECTION_UNKNOWN, ..._REMOTE_DISCONNECTED
		default: false
		}
	}

	/// Settings restarts retry anything except reasons that won't change by trying again
	private static func isRetryableForSettings(quitReason code: Int32) -> Bool {
		switch code {
		case 1, 6, 12, 13: false  // STOPPED, RP_VERSION_MISMATCH, REMOTE_SHUTDOWN, PSN_REGIST_FAILED
		default: true
		}
	}

	/// Reconnects with the current settings after a short wait, retrying until it works
	/// or is cancelled. Another change during the wait starts the wait again.
	private func restartForSettings() {
		cancelReconnect()
		teardown()
		reconnectAttempt = 1
		state = .applyingSettings(attempt: 1)
		let work = DispatchWorkItem { [weak self] in self?.start() }
		reconnectWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsRetryDelay, execute: work)
	}

	/// Waiting to make the first reconnect attempt for new settings
	private var waitingToApplySettings: Bool {
		if case .applyingSettings(attempt: 1) = state, handle == nil, reconnectWork != nil { return true }
		return false
	}

	/// Applies new settings. Codec/resolution/bitrate/HDR/protocol changes need a reconnect.
	/// A pending retry picks up the latest settings when it runs.
	func apply(_ new: StreamSettings) {
		let needsReconnect =
			new.resolution != settings.resolution || new.fps != settings.fps || new.bitrateMbps != settings.bitrateMbps
			|| new.effectiveCodec != settings.effectiveCodec || new.hdr != settings.hdr
			|| new.takionV20 != settings.takionV20 || new.networkSmoothing != settings.networkSmoothing
		let micChanged = new.microphone != settings.microphone
		settings = new
		if micChanged, handle != nil {
			audio.setMic(new.microphone)
			applyMicState()
		}
		input.selectIsTouchpad = new.selectIsTouchpad
		input.gyroAimEnabled = new.gyroAim != .off
		if new.gyroAim == .off, gyroStickPosition != .zero {
			gyroStickPosition = .zero
			sendPad()
		}
		input.feedback.rumbleEnabled = new.rumble
		input.feedback.phoneHapticsScale = new.phoneHaptics.scale
		renderer?.setDisplayMode(new.displayMode)
		if needsReconnect, handle != nil || waitingToApplySettings, !goingToSleep {
			restartForSettings()
		} else {
			configureRenderer()
		}
	}

	/// Frame generation needs a screen that can show twice the stream's frame rate
	private var frameGenerationActive: Bool {
		let screenHz = settings.highRefreshDisplay ? UIScreen.main.maximumFramesPerSecond : 60
		return settings.frameGeneration && settings.fps * 2 <= screenHz
	}

	private func configureRenderer() {
		renderer?.configure(
			hdr: settings.hdr, displayMode: settings.displayMode, upscaling: settings.upscaling,
			frameGeneration: frameGenerationActive, fps: settings.fps,
			frameCapture: settings.frameCapture,
			smoothing: settings.networkSmoothing,
			screenHz: settings.highRefreshDisplay ? UIScreen.main.maximumFramesPerSecond : 60)
	}

	/// Debug: saves the last few seconds of frames (see FrameCapture)
	func saveFrameCapture() {
		guard let renderer, captureStatus != "Saving…" else { return }
		captureStatus = "Saving…"
		renderer.saveCapture { [weak self] result in
			guard let self else { return }
			switch result {
			case .success(let (dir, count)):
				captureStatus = "Saved \(count) frames: Files › iPlay5 › Frame captures › \(dir.lastPathComponent)"
			case .failure(let error):
				captureStatus = "Capture failed: \(error.localizedDescription)"
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
				if self?.captureStatus != "Saving…" { self?.captureStatus = nil }
			}
		}
	}

	func setPaused(_ paused: Bool) {
		guard paused != self.paused else { return }
		self.paused = paused
		renderer?.setPaused(paused)
		audio.muted = paused
		applyMicState()
		if !paused, let handle {
			// We dropped frames while paused, so get a clean keyframe
			ck_session_request_idr(handle)
		}
	}

	func submitPIN(_ pin: String) {
		guard let handle else { return }
		ck_session_set_login_pin(handle, pin)
		state = .connecting
	}

	/// Asks the console to go to rest mode, then ends the session once it closes the
	/// connection (or after a short wait if it doesn't) without offering a reconnect.
	func putConsoleToSleep() {
		guard let handle, !goingToSleep else { return }
		let err = ck_session_goto_bed(handle)
		guard err == 0 else {
			log.error("Rest mode request failed (error \(err))")
			showNotice("Couldn't put \(console.name) in rest mode (error \(err)).")
			return
		}
		goingToSleep = true
		cancelReconnect()
		let work = DispatchWorkItem { [weak self] in self?.finishSleep() }
		sleepWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.sleepTimeout, execute: work)
	}

	private func finishSleep() {
		sleepWork?.cancel()
		sleepWork = nil
		goingToSleep = false
		teardown()
		state = .consoleAsleep
	}

	private func showNotice(_ text: String) {
		notice = text
		noticeWork?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.notice = nil }
		noticeWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
	}

	// MARK: - Microphone

	func toggleMicMuted() {
		micMuted.toggle()
		applyMicState()
	}

	/// Sends mic audio while streaming, unmuted and not paused, and tells the console to match
	private func applyMicState() {
		let streaming = state == .streaming && handle != nil
		micActive = streaming && audio.micEnabled
		let live = micActive && !micMuted && !paused
		audio.micLive = live
		// The first unmute attaches the mic on the console. Don't attach one just to mute it.
		guard let handle, streaming, micConsoleLive != live, live || micConsoleLive != nil else { return }
		let err = ck_session_mic_set_muted(handle, !live)
		if err == 0 {
			micConsoleLive = live
			log.notice("Mic \(live ? "live" : "muted", privacy: .public)")
		} else {
			log.error("Mic \(live ? "unmute" : "mute", privacy: .public) failed (error \(err))")
		}
	}

	// MARK: - Optimise connection

	/// Watches the next few seconds of the stream, then suggests settings
	func startConnectionCheck() {
		guard handle != nil else { return }
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
			let result = check.result(for: settings)
			log.notice("Connection check: \(result.title, privacy: .public). \(result.detail, privacy: .public)")
			connectionCheck = nil
			connectionCheckResult = result
		} else {
			connectionCheck = check
		}
	}

	// MARK: - Text input

	/// Sends the whole text whenever it changes
	func keyboardChanged(_ text: String) {
		guard let handle else { return }
		ck_session_keyboard_set_text(handle, text)
	}

	func keyboardSubmit(_ text: String) {
		guard let handle else { return }
		ck_session_keyboard_set_text(handle, text)
		ck_session_keyboard_accept(handle)
		keyboardText = nil
	}

	func keyboardCancel() {
		if let handle { ck_session_keyboard_reject(handle) }
		keyboardText = nil
	}

	private func teardown() {
		finishQualityReport()
		statsTimer?.invalidate()
		statsTimer = nil
		// A new connection starts fresh counters, so a check in progress can't carry on
		connectionCheck = nil
		input.stop()
		physicalPad = CKPadState()
		gyroStickPosition = .zero
		gyroStick.reset()
		resetScreenInput()
		touchIDs.removeAll()
		audio.stop()
		micActive = false
		micConsoleLive = nil
		if let handle {
			// Stops and joins chiaki's threads: no callbacks after this
			ck_session_destroy(handle)
		}
		handle = nil
		decoder?.invalidate()
		decoder = nil
		connectionRef?.release()
		connectionRef = nil
		connectionID &+= 1
		UIApplication.shared.isIdleTimerDisabled = false
	}

	// MARK: - Callbacks (chiaki threads)

	private func handleVideo(_ buf: UnsafePointer<UInt8>, _ size: Int, _ lost: Int32) -> Bool {
		if lost > 0 {
			lostFrames &+= lost
			renderer?.noteLostFrames()
		}
		// Background decoding fails, and each failure would ask for another keyframe.
		// Coming back unpauses the stream, which asks for one.
		guard let decoder, !backgrounded else { return true }
		return decoder.decode(buf, count: size)
	}


	// MARK: - Events (main thread)

	private func handleEvent(_ type: CKEventType, code: Int32, message: String?, connection: Int) {
		// From a connection we've already torn down
		guard connection == connectionID else { return }
		switch type {
		case CK_EVENT_CONNECTED:
			reconnectAttempt = 0
			state = .streaming
			applyMicState()
		case CK_EVENT_LOGIN_PIN_REQUEST:
			state = .needsPIN(incorrect: code != 0)
		case CK_EVENT_KEYBOARD_OPEN:
			keyboardText = message ?? ""
		case CK_EVENT_KEYBOARD_CLOSE:
			keyboardText = nil
		case CK_EVENT_QUIT:
			// CHIAKI_QUIT_REASON_STOPPED (1) and ..._REMOTE_SHUTDOWN (12) are normal exits
			let wasError = code != 1 && code != 12
			// Only retry a connection that was working (or a retry that just failed)
			let wasPlaying: Bool
			switch state {
			case .streaming, .reconnecting: wasPlaying = true
			default: wasPlaying = false
			}
			// Tear down off the callback thread (we're on main via async)
			teardown()
			if goingToSleep {
				// The console closed the connection because we put it to sleep
				finishSleep()
			} else if case .applyingSettings = state, Self.isRetryableForSettings(quitReason: code) {
				// e.g. the console still thinks the old connection is in use: keep trying
				reconnectAttempt += 1
				let attempt = reconnectAttempt
				log.notice("Reconnect for new settings failed (\(message ?? "?", privacy: .public)), attempt \(attempt)")
				state = .applyingSettings(attempt: attempt)
				let work = DispatchWorkItem { [weak self] in self?.start() }
				reconnectWork = work
				DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsRetryDelay, execute: work)
			} else if wasError, wasPlaying, Self.isRetryable(quitReason: code), reconnectAttempt < Self.maxReconnectAttempts {
				reconnectAttempt += 1
				let attempt = reconnectAttempt
				log.notice("Connection lost (\(message ?? "?", privacy: .public)), reconnect attempt \(attempt)")
				state = .reconnecting(attempt: attempt)
				let work = DispatchWorkItem { [weak self] in self?.start() }
				reconnectWork = work
				// 1 s, 2 s, 4 s
				DispatchQueue.main.asyncAfter(deadline: .now() + pow(2, Double(attempt - 1)), execute: work)
			} else {
				reconnectAttempt = 0
				state = .ended(error: wasError ? message : nil)
			}
		default:
			break
		}
	}

	private func sendPad() {
		guard let handle else { return }
		var pad = physicalPad
		pad.buttons |= virtualPad.buttons
		if psRelease != nil { pad.buttons |= CK_BUTTON_PS.rawValue }
		if !touchpadClicks.isEmpty { pad.buttons |= CK_BUTTON_TOUCHPAD.rawValue }
		pad.l2 = max(pad.l2, virtualPad.l2)
		pad.r2 = max(pad.r2, virtualPad.r2)
		if let stick = virtualPad.leftStick { (pad.left_x, pad.left_y) = (stick.x, stick.y) }
		if let stick = virtualPad.rightStick { (pad.right_x, pad.right_y) = (stick.x, stick.y) }
		if gyroStickPosition != .zero {
			pad.right_x = Int16(clamping: Int(pad.right_x) + Int((gyroStickPosition.x * 32767).rounded()))
			pad.right_y = Int16(clamping: Int(pad.right_y) + Int((gyroStickPosition.y * 32767).rounded()))
		}
		ck_session_set_pad(handle, &pad)
	}

	// MARK: - Gyro aiming (main thread)

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
		case .holdingL2: max(physicalPad.l2, virtualPad.l2) > 30
		case .holdingR1: (physicalPad.buttons | virtualPad.buttons) & CK_BUTTON_R1.rawValue != 0
		}
	}

	// MARK: - On-screen touchpad (main thread)

	func setVirtualPad(_ pad: VirtualPadState) {
		virtualPad = pad
		sendPad()
		input.feedback.screenTriggersMoved(left: Float(pad.l2) / 255, right: Float(pad.r2) / 255)
	}

	func resetScreenInput() {
		let hadButtons = virtualPad != VirtualPadState() || !touchpadClicks.isEmpty || psRelease != nil
		virtualPad = VirtualPadState()
		input.feedback.screenTriggersMoved(left: 0, right: 0)
		touchpadClicks.values.forEach { $0.cancel() }
		touchpadClicks.removeAll()
		psRelease?.cancel()
		psRelease = nil
		if hadButtons { sendPad() }
		// Physical DualSense contacts use slots 0 and 1 and are independent of the screen.
		for slot in touchIDs.keys.filter({ $0 >= 10 }) { handleTouch(.up(slot: slot)) }
	}

	func screenTouch(_ event: ControllerInput.TouchEvent) {
		if case .down(let slot, _, _) = event, let click = touchpadClicks.removeValue(forKey: slot) {
			click.cancel()
			sendPad()
			handleTouch(.up(slot: slot))
		}
		handleTouch(event)
	}

	/// On-screen PS button, for controllers whose home button iOS doesn't pass through.
	func pressPSButton() {
		psRelease?.cancel()
		let work = DispatchWorkItem { [weak self] in
			self?.psRelease = nil
			self?.sendPad()
		}
		psRelease = work
		sendPad()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
	}

	/// A quick tap on the screen: click the touchpad at the touch point, then lift the finger.
	func screenTap(slot: Int) {
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			self.touchpadClicks.removeValue(forKey: slot)
			self.sendPad()
			self.handleTouch(.up(slot: slot))
		}
		touchpadClicks[slot] = work
		sendPad()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
	}

	private func handleTouch(_ event: ControllerInput.TouchEvent) {
		guard let handle else { return }
		switch event {
		case .down(let slot, let x, let y):
			touchIDs[slot] = ck_session_touch_start(handle, x, y)
		case .move(let slot, let x, let y):
			if let id = touchIDs[slot], id >= 0 { ck_session_touch_move(handle, id, x, y) }
		case .up(let slot):
			if let id = touchIDs.removeValue(forKey: slot), id >= 0 { ck_session_touch_stop(handle, id) }
		}
	}

	private func updateStats() {
		guard let decoder else { return }
		let decoded = decoder.decodedFrames
		var s = StreamStats()
		s.fps = Double(decoded - lastDecoded)
		lastDecoded = decoded
		if let handle {
			s.bitrateMbps = ck_session_measured_bitrate_mbps(handle)
			s.rttMs = ck_session_rtt_ms(handle)
			s.packetLoss = ck_session_packet_loss(handle)
			s.takionVersion = Int(ck_session_takion_version(handle))
			if settings.networkSmoothing {
				var net = CKNetStats()
				ck_session_net_stats(handle, &net)
				var smoothing = SmoothingStats()
				smoothing.packetsLate = Int(net.packets_late)
				smoothing.packetsSkipped = Int(net.packets_skipped)
				smoothing.waitMs = net.reorder_wait_ms
				smoothing.fecFailures = Int(net.fec_failures)
				smoothing.framesPatched = Int(net.frames_patched)
				if let pacer = renderer?.smoothingStats {
					smoothing.heldFrames = pacer.depth
					smoothing.droppedFrames = pacer.dropped
					smoothing.underruns = pacer.underruns
				}
				s.smoothing = smoothing
			}
		}
		s.width = decoder.dimensions.width
		s.height = decoder.dimensions.height
		s.decodeMs = decoder.lastDecodeMs
		s.failedFrames = decoder.failedFrames
		s.lostFrames = Int(lostFrames)
		s.hdrFrames = settings.hdr
		s.controller = input.controllerName
		s.displayHz = renderer?.displayHz ?? 0
		if let renderer {
			s.frameGenActive = frameGenerationActive
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
		sampleConnectionCheck(s)
		sampleQuality(s)
	}

	// MARK: - Auto bitrate

	/// Seconds after connecting that are left out: the start can be rough on any network
	private static let qualityWarmupSeconds = 5

	private func sampleQuality(_ s: StreamStats) {
		guard state == .streaming, !paused, !backgrounded else { return }
		qualityStreamingSeconds += 1
		let lost = s.lostFrames + s.failedFrames
		if qualityStreamingSeconds == Self.qualityWarmupSeconds { qualityLostAtStart = lost }
		guard qualityStreamingSeconds > Self.qualityWarmupSeconds else { return }
		qualitySeconds += 1
		qualityLossSum += s.packetLoss
		qualityPeak = max(qualityPeak, s.bitrateMbps)
	}

	private func finishQualityReport() {
		guard handle != nil, qualitySeconds > 0, let decoder else { return }
		let lost = Int(lostFrames) + decoder.failedFrames
		qualityReports.append(StreamQualityReport(
			bitrateMbps: qualityBitrate, seconds: qualitySeconds,
			averageLoss: qualityLossSum / Double(qualitySeconds),
			lostFrames: max(0, lost - qualityLostAtStart), peakMbps: qualityPeak))
		qualitySeconds = 0
	}
}
