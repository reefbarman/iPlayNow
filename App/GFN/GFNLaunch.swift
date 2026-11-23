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

	private(set) var phase: Phase = .checking
	let game: GFNGame
	let variant: GFNGameVariant

	private let accounts: GFNAccountStore
	private let request: GFNStreamRequest
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
			var token = try await accounts.accessToken()
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
			guard var session = current else { return }
			self.session = session
			if Task.isCancelled {
				// cancel() ran while the create was in flight; end what it made
				await end()
				return
			}
			update(session)

			var readyPolls = 0
			var failures = 0
			while true {
				try Task.checkCancellation()
				if isReady(session) {
					readyPolls += 1
					if readyPolls >= (session.status == 3 ? 2 : 3) {
						phase = .ready(session)
						return
					}
				} else {
					readyPolls = 0
				}
				try await Task.sleep(for: .seconds(2))
				token = try await accounts.accessToken()
				do {
					session = try await GFNSessions.poll(token: token, session)
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
		} catch is CancellationError {
		} catch {
			if case GFNError.queueAbandoned = error { session = nil }
			if case GFNError.sessionEnded = error { session = nil }
			fail(error)
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
