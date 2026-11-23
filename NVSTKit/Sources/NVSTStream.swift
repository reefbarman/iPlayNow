import CoreMedia
import CoreVideo
import Foundation
import os

// The public surface of NVSTKit. Everything under Sources/NVST is the vendored OpenNOW receiver;
// this file is iPlayGFN's adapter around it, forked from OpenNOW iOS `NativeStreamNVST.swift`
// (MIT) with the app, WebRTC and diagnostics coupling removed.

public enum NVSTCodec: String, Sendable {
	case h264 = "H264", hevc = "HEVC"
}

public struct NVSTStreamConfig: Sendable {
	public var sessionID: String
	public var rtspsEndpoints: [String]
	public var width: Int
	public var height: Int
	public var fps: Int
	public var maxBitrateKbps: Int
	public var codec: NVSTCodec
	/// 10-bit HDR10 (HEVC only)
	public var hdr: Bool

	public init(sessionID: String, rtspsEndpoints: [String], width: Int, height: Int, fps: Int,
				maxBitrateKbps: Int, codec: NVSTCodec, hdr: Bool = false) {
		self.sessionID = sessionID
		self.rtspsEndpoints = rtspsEndpoints
		self.width = width
		self.height = height
		self.fps = fps
		self.maxBitrateKbps = maxBitrateKbps
		self.codec = codec
		self.hdr = hdr && codec == .hevc
	}
}

/// Xbox-style pad. Sticks -32768...32767, Y up is positive (GameController convention). Triggers 0...255.
public struct NVSTGamepad: Equatable, Sendable {
	public var buttons: UInt16 = 0
	public var leftTrigger: UInt8 = 0
	public var rightTrigger: UInt8 = 0
	public var leftX: Int16 = 0
	public var leftY: Int16 = 0
	public var rightX: Int16 = 0
	public var rightY: Int16 = 0

	public init() {}

	public static let dpadUp: UInt16 = 0x0001
	public static let dpadDown: UInt16 = 0x0002
	public static let dpadLeft: UInt16 = 0x0004
	public static let dpadRight: UInt16 = 0x0008
	public static let start: UInt16 = 0x0010
	public static let back: UInt16 = 0x0020
	public static let leftThumb: UInt16 = 0x0040
	public static let rightThumb: UInt16 = 0x0080
	public static let leftShoulder: UInt16 = 0x0100
	public static let rightShoulder: UInt16 = 0x0200
	public static let guide: UInt16 = 0x0400
	public static let a: UInt16 = 0x1000
	public static let b: UInt16 = 0x2000
	public static let x: UInt16 = 0x4000
	public static let y: UInt16 = 0x8000
}

public enum NVSTEnd: Sendable, Equatable {
	case gameExited, idle, timeLimit, paused
	case host(code: UInt32)
	case failed(String)

	/// Short player-facing text, nil for a normal game exit.
	public var message: String? {
		switch self {
		case .gameExited: return nil
		case .idle: return "The session ended because it was idle for too long."
		case .timeLimit: return "You reached the session time limit for your membership."
		case .paused: return "GeForce NOW paused the session."
		case .host(let code):
			let hex = String(format: "0x%08X", code)
			return "GeForce NOW ended the session (\(hex))."
		case .failed(let reason): return reason
		}
	}

	init(termination: NvstSeatTermination) {
		switch termination.result {
		case 0x8003_0014: self = .gameExited
		case 0x8003_0007: self = .idle
		case 0x8003_000c: self = .timeLimit
		case NvstSeatTermination.sessionPauseResult: self = .paused
		default: self = .host(code: termination.result)
		}
	}
}

/// Cumulative counters, sampled about once a second.
public struct NVSTStats: Sendable {
	public var framesDecoded: Int
	public var bytesReceived: Int
	public var packetsLost: Int
	public var width: Int
	public var height: Int
	public var decodeMs: Double
	public var pingMs: Double
}

public enum NVSTStreamError: LocalizedError, Sendable {
	case noEndpoints, cancelled, failed(String)

	public var errorDescription: String? {
		switch self {
		case .noEndpoints: return "GeForce NOW didn't provide a streaming address for this session."
		case .cancelled: return "The connection was cancelled."
		case .failed(let reason): return reason
		}
	}
}

/// One GeForce NOW stream over NVIDIA's native NVST protocol. Set the callbacks before `start()`.
public final class NVSTStream: @unchecked Sendable {
	/// Decoder thread; '420f' full-range NV12 for SDR.
	public var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
	/// 0...1 motor strengths for pad 0, any thread.
	public var onRumble: (@Sendable (_ low: Float, _ high: Float) -> Void)?
	public var onStats: (@Sendable (NVSTStats) -> Void)?
	/// At most once, any thread; not called for `stop()`.
	public var onEnded: (@Sendable (NVSTEnd) -> Void)?

	public let config: NVSTStreamConfig

	private struct State {
		var runner: NVSTRunner?
		var stopped = false
		var ended = false
		var audioBundle: NvstNativeBundle?
		var rumbleGeneration: UInt64 = 0
	}
	private let state = OSAllocatedUnfairLock(initialState: State())
	private let audio = NVSTAudioRing(capacityFrames: 48_000 * 150 / 1000)
	private let input = NVSTInputGate()
	private let audioQueue = DispatchQueue(label: "dev.reefbarman.iplaygfn.nvst.audio", qos: .userInteractive)
	private let rumbleQueue = DispatchQueue(label: "dev.reefbarman.iplaygfn.nvst.rumble")
	private var audioTimer: DispatchSourceTimer?

	public init(config: NVSTStreamConfig) {
		self.config = config
	}

	deinit { audioTimer?.cancel() }

	/// RTSP negotiation through PLAY. Throws a LocalizedError.
	public func start() async throws {
		guard !config.rtspsEndpoints.isEmpty else { throw NVSTStreamError.noEndpoints }
		let runner = NVSTRunner(config: config, events: makeEvents())
		let proceed = state.withLock { state -> Bool in
			guard !state.stopped, state.runner == nil else { return false }
			state.runner = runner
			return true
		}
		guard proceed else { throw NVSTStreamError.cancelled }
		startAudioPump()
		do {
			try await runner.start()
		} catch {
			stopAudioPump()
			if state.withLock({ $0.stopped }) { throw NVSTStreamError.cancelled }
			if error is LocalizedError { throw error }
			if error is CancellationError { throw NVSTStreamError.cancelled }
			throw NVSTStreamError.failed(error.localizedDescription)
		}
	}

	/// Idempotent: neutral pad, teardown, RTSP TEARDOWN in the background.
	public func stop() {
		let runner = state.withLock { state -> NVSTRunner? in
			guard !state.stopped else { return nil }
			state.stopped = true
			state.audioBundle = nil
			state.rumbleGeneration &+= 1
			return state.runner
		}
		input.deactivate(sendingNeutral: true)
		stopAudioPump()
		audio.reset()
		if let runner { Task.detached { await runner.close() } }
	}

	/// Any thread. Stored until input activates, then sent. Pad 0, bitmap 0x0101.
	public func send(_ pad: NVSTGamepad) {
		input.send(pad)
	}

	public func requestKeyframe() {
		guard let runner = state.withLock({ $0.runner }) else { return }
		Task { await runner.requestKeyframe() }
	}

	/// 48 kHz stereo frames waiting to be read.
	public func audioBuffered() -> Int { audio.bufferedFrames() }

	/// 48 kHz stereo interleaved Float32. Safe on the audio render thread: no actor hops, no
	/// allocation. Returns frames copied; the caller zero-fills the rest.
	public func readAudio(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
		audio.read(out, frames: frames)
	}

	// MARK: - Runner events

	private func makeEvents() -> NVSTRunnerEvents {
		NVSTRunnerEvents(
			frame: { [weak self] buffer in self?.onFrame?(buffer) },
			haptics: { [weak self] events in self?.handleHaptics(events) },
			stats: { [weak self] stats in self?.onStats?(stats) },
			ended: { [weak self] end in self?.finish(end) },
			bundleChanged: { [weak self] bundle in
				guard let self else { return }
				self.state.withLock { state in
					if !state.stopped { state.audioBundle = bundle }
				}
				if bundle == nil { self.input.deactivate(sendingNeutral: false) }
			},
			inputActivated: { [weak self] bundle, clock in self?.input.activate(bundle: bundle, clock: clock) })
	}

	private func finish(_ end: NVSTEnd) {
		let report = state.withLock { state -> Bool in
			guard !state.stopped, !state.ended else { return false }
			state.ended = true
			state.audioBundle = nil
			return true
		}
		guard report else { return }
		input.deactivate(sendingNeutral: false)
		stopAudioPump()
		onEnded?(end)
	}

	private func handleHaptics(_ events: [NvstHapticEvent]) {
		guard let event = events.last(where: { $0.gamepadIndex == 0 }) else { return }
		let low = Float(event.leftMotor) / 65_535
		let high = Float(event.rightMotor) / 65_535
		let generation = state.withLock { state -> UInt64? in
			guard !state.stopped, !state.ended else { return nil }
			state.rumbleGeneration &+= 1
			return state.rumbleGeneration
		}
		guard let generation else { return }
		onRumble?(low, high)
		// A pulse holds the motors for its duration; a state record holds until the next record.
		guard event.durationMilliseconds != nil, !event.isSilent else { return }
		let delay = DispatchTimeInterval.milliseconds(Int(event.effectiveDurationMilliseconds))
		rumbleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
			guard let self, self.state.withLock({ $0.rumbleGeneration == generation }) else { return }
			self.onRumble?(0, 0)
		}
	}

	// MARK: - Audio pump

	/// The bundle's jitter buffer is pull-clocked: each pull advances it by one 5 ms packet. Pull on
	/// our own clock into a ring the render thread can read without locks that allocate.
	private func startAudioPump() {
		audioQueue.sync {
			guard audioTimer == nil else { return }
			let timer = DispatchSource.makeTimerSource(flags: .strict, queue: audioQueue)
			let started = DispatchTime.now().uptimeNanoseconds
			var ticks: UInt64 = 0
			timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
			timer.setEventHandler { [weak self] in
				guard let self else { return }
				let due = (DispatchTime.now().uptimeNanoseconds - started) / 5_000_000
				guard let bundle = self.state.withLock({ $0.audioBundle }) else { ticks = due; return }
				// Catch up after a late wake-up, but never spin through a long stall.
				var pulls = 0
				while ticks < due, pulls < 8 {
					ticks += 1; pulls += 1
					let samples = bundle.pullAudio()
					if !samples.isEmpty { self.audio.write(samples) }
				}
				ticks = due
			}
			audioTimer = timer
			timer.resume()
		}
	}

	private func stopAudioPump() {
		audioQueue.async { [weak self] in
			self?.audioTimer?.cancel()
			self?.audioTimer = nil
		}
	}
}

// MARK: - Audio ring

/// Lock-protected interleaved stereo ring. Writes past capacity drop the oldest audio, which keeps
/// latency bounded when the output clock runs slower than the seat's.
final class NVSTAudioRing: @unchecked Sendable {
	private let capacity: Int  // samples
	private let buffer: UnsafeMutablePointer<Float>
	private let lock = OSAllocatedUnfairLock()
	private var readIndex = 0
	private var count = 0

	init(capacityFrames: Int) {
		capacity = capacityFrames * 2
		buffer = .allocate(capacity: capacity)
		buffer.initialize(repeating: 0, count: capacity)
	}

	deinit { buffer.deallocate() }

	func write(_ samples: [Float]) {
		samples.withUnsafeBufferPointer { source in
			guard var base = source.baseAddress else { return }
			var length = source.count - source.count % 2
			if length > capacity { base += length - capacity; length = capacity }
			lock.lock()
			let overflow = count + length - capacity
			if overflow > 0 {
				readIndex = (readIndex + overflow) % capacity
				count -= overflow
			}
			var writeIndex = (readIndex + count) % capacity
			var remaining = length
			while remaining > 0 {
				let chunk = min(remaining, capacity - writeIndex)
				(buffer + writeIndex).update(from: base, count: chunk)
				base += chunk; remaining -= chunk
				writeIndex = (writeIndex + chunk) % capacity
			}
			count += length
			lock.unlock()
		}
	}

	func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
		lock.lock()
		defer { lock.unlock() }
		let samples = min(max(0, frames) * 2, count)
		var copied = 0
		while copied < samples {
			let chunk = min(samples - copied, capacity - readIndex)
			(out + copied).update(from: buffer + readIndex, count: chunk)
			copied += chunk
			readIndex = (readIndex + chunk) % capacity
		}
		count -= samples
		return samples / 2
	}

	func bufferedFrames() -> Int {
		lock.lock()
		defer { lock.unlock() }
		return count / 2
	}

	func reset() {
		lock.lock()
		readIndex = 0; count = 0
		lock.unlock()
	}
}

// MARK: - Input

/// Serialises gamepad packets for pad 0. Holds the latest state until the seat has activated
/// input, then sends it and every change after.
final class NVSTInputGate: @unchecked Sendable {
	private let queue = DispatchQueue(label: "dev.reefbarman.iplaygfn.nvst.input", qos: .userInteractive)
	private var bundle: NvstNativeBundle?
	private var clock: NvstSessionClock?
	private var latest = NVSTGamepad()
	private var sequence: UInt16 = 0

	func send(_ pad: NVSTGamepad) {
		queue.async { [self] in
			latest = pad
			transmit()
		}
	}

	func activate(bundle: NvstNativeBundle, clock: NvstSessionClock) {
		queue.async { [self] in
			self.bundle = bundle
			self.clock = clock
			transmit()
		}
	}

	func deactivate(sendingNeutral: Bool) {
		queue.sync {
			if sendingNeutral, bundle != nil {
				latest = NVSTGamepad()
				transmit()
			}
			bundle = nil
			clock = nil
		}
	}

	private func transmit() {
		guard let bundle, let clock else { return }
		sequence &+= 1
		let packet = NvstGamepadPacket(sequence: sequence, timestampMicroseconds: clock.elapsedMicroseconds(),
			buttons: latest.buttons, leftTrigger: latest.leftTrigger, rightTrigger: latest.rightTrigger,
			leftStickX: latest.leftX, leftStickY: latest.leftY, rightStickX: latest.rightX, rightStickY: latest.rightY)
		if let encoded = try? packet.command.encoded { _ = bundle.sendInput(encoded) }
	}
}

// MARK: - Runner

struct NVSTRunnerEvents: Sendable {
	let frame: @Sendable (CVPixelBuffer) -> Void
	let haptics: @Sendable ([NvstHapticEvent]) -> Void
	let stats: @Sendable (NVSTStats) -> Void
	let ended: @Sendable (NVSTEnd) -> Void
	let bundleChanged: @Sendable (NvstNativeBundle?) -> Void
	let inputActivated: @Sendable (NvstNativeBundle, NvstSessionClock) -> Void
}

private struct NVSTVideoLiveness {
	enum Action: Equatable { case none, requestKeyframe, failed }
	private var lastProgressAt: UInt64
	private var lastDecoded: UInt64 = 0
	private var lastRequestAt: UInt64?

	init(now: UInt64) { lastProgressAt = now }

	mutating func observe(decoded: UInt64, now: UInt64) -> Action {
		if decoded > lastDecoded {
			lastDecoded = decoded
			lastProgressAt = now
			lastRequestAt = nil
			return .none
		}
		let age = now >= lastProgressAt ? now - lastProgressAt : 0
		if age >= 20_000_000_000 { return .failed }
		guard age >= 1_000_000_000 else { return .none }
		if let lastRequestAt, now >= lastRequestAt, now - lastRequestAt < 1_000_000_000 { return .none }
		lastRequestAt = now
		return .requestKeyframe
	}
}

/// Owns the NVST pieces for one session: RTSP, the Mjolnir video receiver, the decoder and the
/// DTLS/SCTP bundle (control, input, feedback, audio).
actor NVSTRunner {
	private let config: NVSTStreamConfig
	private let events: NVSTRunnerEvents
	private let clock = NvstSessionClock()
	private var reserver: NvstLocalBundleReserver?
	private var rtsp: NvstRtspSession?
	private var receiver: NvstMjolnirReceiver?
	private var bundle: NvstNativeBundle?
	private var decoder: NvstVideoToolboxDecoder?
	private var pipeline: NvstVideoPipeline?
	private let feedback = NvstFeedbackSender()
	private var stopped = false
	private var didFinish = false
	private var bundleGeneration: UInt64 = 0
	private var preparationError: Error?
	private var sampling: Task<Void, Never>?
	private var keepalive: Task<Void, Never>?
	private var qos: Task<Void, Never>?
	private var activatedInput = false
	private var qosSequence: UInt32 = 0
	private var lastQosBytes: UInt64 = 0
	private var lastDelay: UInt32 = 0
	private var lastRtpStatsFrame: UInt64 = 0
	private var lastControlStatsAt: Date?
	private var lastKeyframeRequestAt: Date?
	private var videoLiveness = NVSTVideoLiveness(now: DispatchTime.now().uptimeNanoseconds)

	init(config: NVSTStreamConfig, events: NVSTRunnerEvents) {
		self.config = config
		self.events = events
	}

	func start() async throws {
		guard !stopped else { throw CancellationError() }
		clock.start()
		let reserver = NvstLocalBundleReserver(bundleProvider: { [weak self] handoff, micOffered in
			await self?.prepareBundle(handoff: handoff, microphoneOffered: micOffered)
		})
		self.reserver = reserver
		let input = NvstRtspNegotiationInput(sessionID: config.sessionID, rtspsEndpoints: config.rtspsEndpoints,
			resolution: "\(config.width)x\(config.height)", fps: config.fps, codec: config.codec.rawValue,
			bitrateKbps: config.maxBitrateKbps, maximumBitrateKbps: config.maxBitrateKbps,
			colorQuality: config.hdr ? "10bit_420" : "8bit_420", hdrEnabled: config.hdr, audioChannelCount: 2, rtcpOnSctp: true,
			disablesOwdCongestionControl: false, vsyncMode: .adaptive,
			announceOverrides: [("x-nv-vqos[0].dfc.enable", "0")])
		do {
			let negotiated = try await NvstRtspNegotiator(reserver: reserver, onProgress: { _ in }).negotiate(input,
				onVideoReady: { [weak self] handoff in
					guard let self else { throw CancellationError() }
					try await self.startVideo(handoff)
				}, onAnnounceReady: { [weak self] _ in await self?.punchBeforePlay() })
			if stopped || didFinish || Task.isCancelled {
				await negotiated.release("cancelled")
				throw CancellationError()
			}
			rtsp = negotiated
			if let preparationError { throw preparationError }
			videoLiveness = NVSTVideoLiveness(now: DispatchTime.now().uptimeNanoseconds)
			sampling = Task { [weak self] in
				while !Task.isCancelled {
					await self?.sample()
					do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
				}
			}
		} catch {
			await close()
			throw error
		}
	}

	private func prepareBundle(handoff: NVSTVideoHandoff, microphoneOffered: Bool) async -> NvstBundleReservation? {
		guard !stopped else { return nil }
		do {
			let nativeBundle = NvstNativeBundle(handoff: handoff, identity: try NvstDtlsIdentity(),
				audioChannelCount: 2, startsAudioDevice: false, logger: nil)
			bundle = nativeBundle
			let generation = bundleGeneration
			feedback.configure(channelWriter: { [weak nativeBundle] data in _ = nativeBundle?.sendFeedback(data) },
							   senderSSRC: NvstVideoReceiver.clientSSRC, mediaSSRC: 0)
			nativeBundle.onControlChannelOpen = { [weak self] in Task { await self?.ifCurrent(generation) { $0.controlOpened() } } }
			nativeBundle.onPartiallyReliableControlOpen = { [weak self] in Task { await self?.ifCurrent(generation) { $0.qosOpened() } } }
			nativeBundle.onFeedbackChannelOpen = { [weak self] in Task { await self?.ifCurrent(generation) { $0.feedbackOpened() } } }
			nativeBundle.onInputProtocolNegotiated = { [weak self] _ in Task { await self?.ifCurrent(generation) { $0.activateInput() } } }
			nativeBundle.onSeatTermination = { [weak self] event in
				Task { await self?.ifCurrent(generation) { $0.finish(NVSTEnd(termination: event)) } }
			}
			nativeBundle.onFailure = { [weak self] reason in
				Task { await self?.ifCurrent(generation) { $0.finish(.failed(reason)) } }
			}
			let haptics = events.haptics
			nativeBundle.onHapticEvents = { events in haptics(events) }
			let identity = try await nativeBundle.prepare(microphone: nil, audioChannelCount: 2)
			guard !stopped else { nativeBundle.close(); return nil }
			pipeline?.attach(bundle: nativeBundle)
			events.bundleChanged(nativeBundle)
			return NvstBundleReservation(bundlePort: identity.bundlePort, mjolnirPort: handoff.mjolnirUDPPort ?? handoff.clientUDPPort,
				localAddress: identity.localAddress, iceCredentials: reserver?.localIceCredentials,
				dtlsFingerprint: identity.dtlsFingerprint, microphoneNegotiated: nativeBundle.microphoneNegotiation.negotiated,
				microphoneSenderSsrc: nativeBundle.microphoneNegotiation.senderSsrc)
		} catch { preparationError = error; return nil }
	}

	private func startVideo(_ handoff: NVSTVideoHandoff) throws {
		guard !stopped else { throw CancellationError() }
		if let preparationError { throw preparationError }
		// Video must be armed before ANNOUNCE. The bundle identity is prepared during ANNOUNCE,
		// then attached to this pipeline before PLAY begins.
		bundleGeneration &+= 1
		receiver?.stop(); pipeline?.stop(); decoder?.invalidate()
		if bundle != nil { events.bundleChanged(nil) }
		bundle?.close(); bundle = nil
		keepalive?.cancel(); keepalive = nil; qos?.cancel(); qos = nil
		feedback.stop(); activatedInput = false
		preparationError = nil; lastQosBytes = 0; lastDelay = 0; qosSequence = 0
		lastKeyframeRequestAt = nil; lastRtpStatsFrame = 0; lastControlStatsAt = nil

		let decoder = NvstVideoToolboxDecoder(codec: handoff.codec, requiresTenBit444: false)
		self.decoder = decoder
		let frame = events.frame
		decoder.onPixelBuffer = { pixelBuffer, _, _ in frame(pixelBuffer) }
		let pipeline = NvstVideoPipeline(decoder: decoder, clock: clock,
			frameTimeMicroseconds: UInt32(1_000_000 / max(1, config.fps)),
			displayVsyncMicroseconds: UInt32(1_000_000 / max(1, config.fps)),
			logger: nil, mediaSink: nil,
			onKeyframeNeeded: { [weak self] in Task { await self?.requestKeyframe() } },
			onFatalDecodeError: { [weak self] reason in Task { await self?.finish(.failed(reason)) } })
		self.pipeline = pipeline
		pipeline.attach(bundle: bundle)
		let descriptor = reserver?.takeMjolnirDescriptor() ?? -1
		let receiver = try NvstMjolnirReceiver(handoff: handoff, sendsReceiverReports: false, existingDescriptor: descriptor)
		self.receiver = receiver
		receiver.onAccessUnit = { unit in pipeline.submit(unit) }
		receiver.onRecoveryNeeded = { [weak self] _ in Task { await self?.requestKeyframe() } }
		feedback.setReportProvider { [weak receiver] in receiver?.receiverReportBlock() }
		try receiver.start()
	}

	private func punchBeforePlay() async {
		receiver?.beginHolePunch()
		try? await Task.sleep(nanoseconds: 60_000_000)
	}

	private func ifCurrent(_ generation: UInt64, _ action: @Sendable (isolated NVSTRunner) -> Void) {
		guard !stopped, generation == bundleGeneration else { return }
		action(self)
	}

	private func controlOpened() {
		guard !stopped, keepalive == nil else { return }
		_ = bundle?.sendControl(.windowStateChange())
		_ = bundle?.sendControl(.systemStateChange())
		requestKeyframe()
		keepalive = Task { [weak self] in
			while !Task.isCancelled {
				await self?.sendKeepalive()
				do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
			}
		}
	}

	private func sendKeepalive() {
		guard !stopped else { return }
		_ = bundle?.sendControl(.pingBackAck(streamValue: UInt32(truncatingIfNeeded: receiver?.feedbackCounters.framesEmitted ?? 0)))
	}

	private func feedbackOpened() {
		guard !stopped else { return }
		if let ssrc = receiver?.stats.boundSSRC { feedback.updateMediaSSRC(ssrc) }
		feedback.start()
	}

	private func qosOpened() {
		guard !stopped, qos == nil else { return }
		qos = Task { [weak self] in
			while !Task.isCancelled {
				await self?.sendQos()
				do { try await Task.sleep(nanoseconds: UInt64(NvstQosReport.interval * 1_000_000_000)) } catch { return }
			}
		}
	}

	private func sendQos() {
		guard !stopped, let bundle, let receiver else { return }
		let counters = receiver.feedbackCounters
		let stats = receiver.stats
		qosSequence &+= 1
		let delay = UInt32(clamping: Int(Double(stats.lastJitter) * 1_000_000 / 90_000))
		let delta = counters.bytesReceived >= lastQosBytes ? counters.bytesReceived - lastQosBytes : 0
		let report = NvstQosReport(sequence: qosSequence, framesReceived: UInt32(truncatingIfNeeded: counters.framesEmitted),
			bytesReceived: UInt32(truncatingIfNeeded: counters.bytesReceived),
			linkCapabilityKbps: UInt16(clamping: max(Int(NvstQosReport.defaultLinkCapabilityKbps), config.maxBitrateKbps)),
			rtpTimestamp: counters.lastRtpTimestamp, previousBytesReceived: UInt32(truncatingIfNeeded: lastQosBytes),
			delayMicroseconds: delay, delayTrendMicroseconds: delay > lastDelay ? delay - lastDelay : lastDelay - delay,
			intervalBits: UInt32(clamping: delta * 8), isWarmedUp: clock.elapsedMicroseconds() >= 1_900_000)
		_ = bundle.sendPartiallyReliableControl(report.command)
		lastQosBytes = counters.bytesReceived; lastDelay = delay
		if stats.framesEmitted >= lastRtpStatsFrame + NvstRtpStatsReport.frameInterval {
			lastRtpStatsFrame = stats.framesEmitted
			let frame = UInt32(truncatingIfNeeded: stats.framesEmitted)
			let report = NvstRtpStatsReport(frameNumber: frame, totalReceivedPackets: stats.authenticatedPackets,
				outOfOrderPackets: UInt32(clamping: stats.outOfOrderPackets), dropEvents: UInt32(clamping: stats.recoveries),
				latePackets: UInt32(clamping: stats.latePackets), droppedPackets: UInt32(clamping: stats.droppedPackets),
				recoveredPackets: UInt32(clamping: stats.recoveredPackets), maxDropBurstLength: stats.maxLossBurst,
				maxWaitingQueueDepth: stats.maxReorderDepth, duplicatePackets: UInt32(clamping: stats.duplicatePackets),
				micChatSentDataBytes: bundle.microphoneSentBytes)
			_ = bundle.sendPartiallyReliableControl(report.command)
			_ = bundle.sendPartiallyReliableControl(NvstRtpNackStatsReport(frameNumber: frame).command)
		}
		if lastControlStatsAt.map({ Date().timeIntervalSince($0) >= NvstControlChannelStatsReport.transmitInterval }) ?? true {
			let stats = bundle.controlChannelStats
			_ = bundle.sendPartiallyReliableControl(NvstControlChannelStatsReport(timestampMicroseconds: clock.elapsedMicroseconds(),
				totalMessagesSent: stats.totalSent, totalMessagesFailed: stats.totalFailed, totalBytesSent: stats.totalBytes,
				commands: stats.commands).command)
			lastControlStatsAt = Date()
		}
	}

	private func activateInput() {
		guard !stopped, !activatedInput, let bundle, bundle.isInputReady else { return }
		activatedInput = true
		let bitmap = NvstGamepadPacket.connectedBitmap
		_ = bundle.sendControl(NvstInputActivation.enableInput(counter: 1, isEnabled: false))
		_ = bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: clock.elapsedMicroseconds(), connectedBitmap: bitmap))
		_ = bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: true))
		_ = bundle.sendControl(NvstInputActivation.mimicRemoteCursor(isEnabled: true))
		_ = bundle.sendControl(.windowStateChange()); _ = bundle.sendControl(.systemStateChange())
		_ = bundle.sendControl(NvstInputActivation.enableInput(counter: UInt32(clamping: (pipeline?.snapshot.frameAcksSent ?? 0) + 1)))
		let haptics = NvstRemoteInput.framed(NvstRemoteInput.hapticsState(enabled: true),
			framing: .enveloped, sequence: 0, timestampMicroseconds: clock.elapsedMicroseconds())
		_ = bundle.sendControl(NvstControlCommand(code: .remoteInput, payload: haptics))
		events.inputActivated(bundle, clock)
	}

	func requestKeyframe() {
		guard !stopped, lastKeyframeRequestAt.map({ Date().timeIntervalSince($0) >= 0.25 }) ?? true else { return }
		lastKeyframeRequestAt = Date()
		// A PLI on an unopened feedback channel can be discarded silently, so the explicit IDR
		// command on the reliable control channel goes first, with UDP as the fallback.
		if bundle?.sendControl(.idrRequest()) != true { receiver?.requestKeyframe() }
		if bundle?.isFeedbackChannelOpen == true {
			if let ssrc = receiver?.stats.boundSSRC { feedback.updateMediaSSRC(ssrc) }
			try? feedback.sendKeyframeRequestNow()
			feedback.requestKeyframe()
		}
	}

	private func sample() async {
		guard !stopped, let receiver, let decoder, let pipeline else { return }
		let stats = receiver.stats
		if let ssrc = stats.boundSSRC { feedback.updateMediaSSRC(ssrc) }
		let decoded = decoder.decodedFrameCount
		switch videoLiveness.observe(decoded: decoded, now: DispatchTime.now().uptimeNanoseconds) {
		case .none: break
		case .requestKeyframe: requestKeyframe()
		case .failed:
			finish(.failed(bundle?.isControlChannelOpen == true
				? "The stream stopped sending video."
				: "Couldn't connect to the game's stream."))
			return
		}
		let counters = receiver.feedbackCounters
		var ping = receiver.roundTripMilliseconds
		if ping < 0, let rtsp { ping = await rtsp.controlRoundTripMilliseconds() }
		guard !stopped else { return }
		let size = (decoder.decodedResolution ?? "").split(separator: "x").compactMap { Int($0) }
		events.stats(NVSTStats(framesDecoded: Int(clamping: decoded), bytesReceived: Int(clamping: counters.bytesReceived),
			packetsLost: Int(clamping: stats.finalizedLossPackets),
			width: size.count == 2 ? size[0] : 0, height: size.count == 2 ? size[1] : 0,
			decodeMs: pipeline.snapshot.decodeP50Milliseconds, pingMs: max(0, ping)))
	}

	private func finish(_ end: NVSTEnd) {
		guard !stopped, !didFinish else { return }
		didFinish = true
		events.ended(end)
		Task { await self.close() }
	}

	func close() async {
		guard !stopped else { return }
		stopped = true
		bundleGeneration &+= 1
		sampling?.cancel(); sampling = nil
		keepalive?.cancel(); keepalive = nil
		qos?.cancel(); qos = nil
		feedback.stop()
		receiver?.stop(); receiver = nil
		pipeline?.stop(); pipeline?.attach(bundle: nil); pipeline = nil
		bundle?.close(); bundle = nil
		// Hardware teardown can wait for output callbacks; keep it off the main actor.
		decoder?.invalidate(); decoder = nil
		reserver?.release(); reserver = nil
		let session = rtsp; rtsp = nil
		await session?.release("client closed")
	}
}
