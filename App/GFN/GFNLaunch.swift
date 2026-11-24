import Foundation
import Observation

/// Drives one launch from create to a rig that's ready to stream. The UI observes `phase`.
@MainActor @Observable
final class GFNLaunch {
	enum Phase: Equatable {
		case checking
		case queued(position: Int)
		case settingUp
		case ready(GFNSession)
		case failed(String)
		case sessionLimit([GFNRemoteSession])
	}

	private(set) var phase: Phase = .checking {
		didSet { if phase != oldValue { onPhase?(phase) } }
	}
	/// Called on every phase change
	@ObservationIgnored var onPhase: ((Phase) -> Void)?
	let game: GFNGame
	let variant: GFNGameVariant

	private let accounts: GFNAccountStore
	private var request: GFNStreamRequest
	private var session: GFNSession?
	private var task: Task<Void, Never>?

	init(accounts: GFNAccountStore, game: GFNGame, variant: GFNGameVariant, request: GFNStreamRequest) {
		self.accounts = accounts
		self.game = game
		self.variant = variant
		self.request = request
	}

	/// Checks for sessions already running, then creates one (or picks up our own queued one) and
	/// polls until the rig is ready.
	func start() {
		task?.cancel()
		phase = .checking
		task = Task { [weak self] in await self?.run() }
	}

	/// The stream dropped but the session may still be alive: claim the same rig back and wait
	/// until it's ready again. Ends in `.ready` or `.failed`, like `start()`.
	func rejoin() {
		task?.cancel()
		guard session != nil else {
			phase = .failed("The GeForce NOW session has ended.")
			return
		}
		phase = .settingUp
		task = Task { [weak self] in await self?.runRejoin() }
	}

	/// A session we could still rejoin
	var canRejoin: Bool { session != nil }

	/// Resolution and frame rate for the next `start()`
	func setRequest(_ request: GFNStreamRequest) {
		self.request = request
	}

	/// For `.sessionLimit`: end the sessions in the way and try again
	func stopOtherSessionsAndRetry() {
		guard case .sessionLimit(let others) = phase else { return }
		task?.cancel()
		phase = .checking
		task = Task { [weak self] in
			guard let self else { return }
			do {
				let token = try await accounts.accessToken()
				guard let provider = accounts.account?.provider else { throw GFNError.notSignedIn }
				for other in others { try await GFNSessions.stop(token: token, other, provider: provider) }
				// CloudMatch takes a moment to free the slot
				try await Task.sleep(for: .seconds(2))
				await run()
			} catch is CancellationError {
			} catch {
				fail(error)
			}
		}
	}

	/// Stops polling and ends our session if one was created
	func cancel() async {
		task?.cancel()
		task = nil
		await end()
	}

	/// Ends the session on GeForce NOW so it doesn't linger on the account
	func end() async {
		guard let session else { return }
		self.session = nil
		guard let token = try? await accounts.accessToken() else { return }
		do {
			try await GFNSessions.stop(token: token, session)
		} catch {
			log.error("Couldn't stop GeForce NOW session \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
		}
	}

	// MARK: -

	private func run() async {
		do {
			guard let provider = accounts.account?.provider else { throw GFNError.notSignedIn }
			let token = try await accounts.accessToken()
			let running = (try? await GFNSessions.active(token: token, provider: provider)) ?? []

			var current: GFNSession?
			if let ours = running.first(where: { $0.appID == variant.id && $0.status == 1 }) {
				// Still queued for this game, maybe from an earlier attempt: keep our place
				current = GFNSession(id: ours.id, appID: ours.appID, status: 1, queuePosition: nil, seatSetupStep: nil,
					rtspsEndpoints: [], baseURL: provider.streamingURL, controlBaseURL: ours.controlBaseURL,
					serverHost: ours.serverHost, clientID: UUID().uuidString, deviceID: GFNDevice.id)
			} else {
				// A ready or streaming session of this game can't be joined without a hand-over,
				// so end it and start fresh. Anything else is the player's call.
				for same in running where same.appID == variant.id {
					try? await GFNSessions.stop(token: token, same, provider: provider)
				}
				let others = running.filter { $0.appID != variant.id }
				if !others.isEmpty {
					phase = .sessionLimit(others)
					return
				}
			}

			if current == nil {
				do {
					current = try await GFNSessions.create(token: token, provider: provider, game: game, variant: variant, request: request)
				} catch GFNError.sessionLimit(let others) {
					phase = .sessionLimit(others)
					return
				}
			}
			guard let session = current else { return }
			self.session = session
			if Task.isCancelled {
				// cancel() ran while the create was in flight; end what it made
				await end()
				return
			}
			update(session)
			try await waitUntilReady(session)
		} catch is CancellationError {
		} catch {
			if case GFNError.queueAbandoned = error { session = nil }
			if case GFNError.sessionEnded = error { session = nil }
			fail(error)
		}
	}

	private func runRejoin() async {
		do {
			guard var current = session else { return }
			var token = try await accounts.accessToken()
			// See where the rig stands first: still queued needs no claim, ended can't be rejoined
			if let polled = try? await GFNSessions.poll(token: token, current) {
				current = polled
				session = polled
			}
			try Task.checkCancellation()
			if current.status != 1 {
				token = try await accounts.accessToken()
				current = try await GFNSessions.claim(token: token, current, game: game, variant: variant, request: request)
				session = current
			}
			try Task.checkCancellation()
			// The rig takes a moment to swap clients; don't go back to it on the old details
			try await waitUntilReady(current, freshPolls: true)
		} catch is CancellationError {
		} catch {
			if case GFNError.sessionEnded = error { session = nil }
			fail(error)
		}
	}

	/// Polls until the rig has stayed ready for a couple of polls, then moves to `.ready`.
	/// freshPolls: don't trust `session`'s current details, poll at least once first.
	private func waitUntilReady(_ start: GFNSession, freshPolls: Bool = false) async throws {
		var session = start
		var readyPolls = 0
		var failures = 0
		var polled = !freshPolls
		while true {
			try Task.checkCancellation()
			if polled, isReady(session) {
				readyPolls += 1
				if readyPolls >= (session.status == 3 ? 2 : 3) {
					phase = .ready(session)
					return
				}
			} else {
				readyPolls = 0
			}
			try await Task.sleep(for: .seconds(freshPolls && !polled ? 1 : 2))
			let token = try await accounts.accessToken()
			do {
				session = try await GFNSessions.poll(token: token, session)
				polled = true
				failures = 0
				self.session = session
				update(session)
			} catch let error as GFNError {
				throw error
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				// Brief network trouble shouldn't lose the queue place
				failures += 1
				if failures >= 8 { throw error }
			}
		}
	}

	private func isReady(_ session: GFNSession) -> Bool {
		(session.status == 2 || session.status == 3)
			&& (session.queuePosition ?? 0) <= 1
			&& !session.rtspsEndpoints.isEmpty
	}

	private func update(_ session: GFNSession) {
		guard session.status == 1 else {
			if !isReady(session) { phase = .settingUp }
			return
		}
		let position = session.queuePosition ?? 0
		let step = session.seatSetupStep ?? 0
		if step == 1 || position > 1 || (position == 1 && step < 3) {
			phase = .queued(position: max(position, 1))
		} else {
			phase = .settingUp
		}
	}

	private func fail(_ error: Error) {
		phase = .failed(error.localizedDescription)
	}
}
