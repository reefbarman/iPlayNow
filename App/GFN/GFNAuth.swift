import AuthenticationServices
import CryptoKit
import Foundation
import Network
import UIKit

/// NVIDIA sign-in: OAuth with PKCE in an ASWebAuthenticationSession, token refresh, user and
/// membership details, and the list of alliance partners.
enum GFNAuth {
	// MARK: - Providers

	/// NVIDIA plus every alliance partner, in GeForce NOW's own order. Falls back to NVIDIA alone.
	static func providers() async -> [GFNProvider] {
		guard let (data, response) = try? await GFNHTTP.send(GFNConstants.serviceURLs, headers: GFNHTTP.oauthHeaders),
			  response.statusCode == 200 else { return [.nvidia] }
		let providers = parseProviders(GFNHTTP.json(data))
		return providers.isEmpty ? [.nvidia] : providers
	}

	static func parseProviders(_ json: [String: Any]) -> [GFNProvider] {
		let info = json["gfnServiceInfo"] as? [String: Any]
		let endpoints = info?["gfnServiceEndpoints"] as? [[String: Any]] ?? []
		let ranked = endpoints.compactMap { item -> (GFNProvider, Int)? in
			guard let idp = GFNHTTP.string(item["idpId"]),
				  let raw = GFNHTTP.string(item["streamingServiceUrl"]),
				  let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
				  let host = parts.host?.lowercased(), !host.isEmpty, !host.hasPrefix("."), !host.contains("..")
			else { return nil }
			let port = parts.port.map { $0 == 443 ? "" : ":\($0)" } ?? ""
			guard let url = URL(string: "https://\(host)\(port)/") else { return nil }
			let code = GFNHTTP.string(item["loginProviderCode"]) ?? "NVIDIA"
			var name = GFNHTTP.string(item["loginProviderDisplayName"]) ?? code
			if code == "BPC" { name = "bro.game" }
			let priority = GFNHTTP.int(item["loginProviderPriority"]) ?? 0
			return (GFNProvider(id: idp, code: code, name: name, streamingURL: url), priority)
		}
		return ranked
			.sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
			.map(\.0)
	}

	// MARK: - Sign in

	@MainActor
	static func signIn(with provider: GFNProvider) async throws -> GFNAccount {
		let verifier = String((0..<64).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".randomElement()! })
		let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		var parts = URLComponents(url: GFNConstants.authorizeURL, resolvingAgainstBaseURL: false)!
		parts.queryItems = [
			.init(name: "response_type", value: "code"),
			.init(name: "device_id", value: GFNDevice.id),
			.init(name: "scope", value: GFNConstants.scopes),
			.init(name: "client_id", value: GFNConstants.clientID),
			.init(name: "redirect_uri", value: GFNConstants.redirectURI),
			.init(name: "ui_locales", value: "en_US"),
			.init(name: "nonce", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
			.init(name: "prompt", value: "select_account"),
			.init(name: "code_challenge", value: challenge),
			.init(name: "code_challenge_method", value: "S256"),
			.init(name: "idp_id", value: provider.id),
		]

		let loopback = GFNLoopbackRedirect()
		try loopback.start()
		defer { loopback.stop() }
		let callback = try await GFNWebSignIn().run(url: parts.url!)

		let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
		if let error = items.first(where: { $0.name == "error" })?.value {
			let detail = items.first(where: { $0.name == "error_description" })?.value
			throw GFNError.server(detail ?? "Sign-in failed (\(error)).")
		}
		guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
			throw GFNError.server("Sign-in didn't return an authorisation code.")
		}

		var headers = GFNHTTP.oauthHeaders
		headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
		let body = GFNHTTP.formBody([
			"grant_type": "authorization_code",
			"code": code,
			"redirect_uri": GFNConstants.redirectURI,
			"code_verifier": verifier,
		])
		let (data, response) = try await GFNHTTP.send(GFNConstants.tokenURL, method: "POST", headers: headers, body: body, timeout: 60)
		guard response.statusCode == 200 else {
			throw GFNError.server(GFNHTTP.message(data, fallback: "NVIDIA couldn't finish signing in."))
		}
		var tokens = try tokens(from: GFNHTTP.json(data), previous: nil)
		if let client = try? await clientToken(accessToken: tokens.accessToken) {
			tokens.clientToken = client.token
			tokens.clientTokenExpiresAt = client.expiresAt
		}
		var account = try await account(provider: provider, tokens: tokens)
		account.tier = await membershipTier(token: tokens.apiToken, userID: account.userID, provider: provider) ?? account.tier
		return account
	}

	// MARK: - Refresh

	/// Refreshes within 10 minutes of expiry, preferring the client token and falling back to the
	/// refresh token. Returns the account unchanged when it's still fresh.
	static func refreshed(_ account: GFNAccount) async throws -> GFNAccount {
		let tokens = account.tokens
		guard Date() >= tokens.expiresAt.addingTimeInterval(-600) else { return account }
		var headers = GFNHTTP.oauthHeaders
		headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"

		var attempts: [[String: String]] = []
		if let client = tokens.clientToken, !client.isEmpty,
		   tokens.clientTokenExpiresAt.map({ Date() < $0.addingTimeInterval(-300) }) ?? true {
			attempts.append([
				"grant_type": "urn:ietf:params:oauth:grant-type:client_token",
				"client_token": client,
				"client_id": GFNConstants.clientID,
				"sub": account.userID,
			])
		}
		if let refresh = tokens.refreshToken {
			attempts.append(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": GFNConstants.clientID])
		}
		guard !attempts.isEmpty else { throw GFNError.notSignedIn }

		var lastError: Error = GFNError.notSignedIn
		for fields in attempts {
			do {
				let (data, response) = try await GFNHTTP.send(GFNConstants.tokenURL, method: "POST", headers: headers, body: GFNHTTP.formBody(fields))
				guard response.statusCode == 200 else {
					lastError = response.statusCode == 400 || response.statusCode == 401
						? GFNError.notSignedIn
						: GFNError.server(GFNHTTP.message(data, fallback: "Couldn't refresh your sign-in."))
					continue
				}
				var updated = account
				updated.tokens = try self.tokens(from: GFNHTTP.json(data), previous: tokens)
				if let client = try? await clientToken(accessToken: updated.tokens.accessToken) {
					updated.tokens.clientToken = client.token
					updated.tokens.clientTokenExpiresAt = client.expiresAt
				}
				return updated
			} catch {
				lastError = error
			}
		}
		throw lastError
	}

	// MARK: - Helpers

	private static func tokens(from json: [String: Any], previous: GFNTokens?) throws -> GFNTokens {
		guard let access = GFNHTTP.string(json["access_token"]) else {
			throw GFNError.server("NVIDIA's sign-in response was missing a token.")
		}
		let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 86_400
		return GFNTokens(
			accessToken: access,
			refreshToken: GFNHTTP.string(json["refresh_token"]) ?? previous?.refreshToken,
			idToken: GFNHTTP.string(json["id_token"]) ?? previous?.idToken,
			expiresAt: Date().addingTimeInterval(expiresIn),
			clientToken: previous?.clientToken,
			clientTokenExpiresAt: previous?.clientTokenExpiresAt
		)
	}

	private static func clientToken(accessToken: String) async throws -> (token: String, expiresAt: Date) {
		var headers = GFNHTTP.oauthHeaders
		headers["Authorization"] = "Bearer \(accessToken)"
		let (data, response) = try await GFNHTTP.send(GFNConstants.clientTokenURL, headers: headers)
		let json = GFNHTTP.json(data)
		guard response.statusCode == 200, let token = GFNHTTP.string(json["client_token"]) else {
			throw GFNError.server("No client token")
		}
		let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
		return (token, Date().addingTimeInterval(expiresIn))
	}

	/// User details come from the id token's claims, or /userinfo if it has none.
	private static func account(provider: GFNProvider, tokens: GFNTokens) async throws -> GFNAccount {
		var claims = jwtClaims(tokens.apiToken)
		var tier = GFNHTTP.string(claims["gfn_tier"])
		if GFNHTTP.string(claims["sub"]) == nil {
			var headers = GFNHTTP.oauthHeaders
			headers["Authorization"] = "Bearer \(tokens.accessToken)"
			let (data, response) = try await GFNHTTP.send(GFNConstants.userInfoURL, headers: headers)
			guard response.statusCode == 200 else { throw GFNError.server("Couldn't load your NVIDIA account.") }
			claims = GFNHTTP.json(data)
			tier = nil
		}
		guard let userID = GFNHTTP.string(claims["sub"]) else { throw GFNError.server("Couldn't load your NVIDIA account.") }
		let email = GFNHTTP.string(claims["email"])
		let name = GFNHTTP.string(claims["preferred_username"])
			?? email.flatMap { $0.split(separator: "@").first.map(String.init) }
			?? "GeForce NOW member"
		return GFNAccount(provider: provider, userID: userID, displayName: name, email: email, tier: tier, tokens: tokens)
	}

	static func membershipTier(token: String, userID: String, provider: GFNProvider) async -> String? {
		let vpc = await GFNServerInfo.vpcID(token: token, provider: provider) ?? "NP-AMS-08"
		var parts = URLComponents(url: GFNConstants.subscriptionsURL, resolvingAgainstBaseURL: false)!
		parts.queryItems = [
			.init(name: "serviceName", value: "gfn_pc"),
			.init(name: "languageCode", value: "en_US"),
			.init(name: "vpcId", value: vpc),
			.init(name: "userId", value: userID),
		]
		var headers = GFNHTTP.desktopHeaders(token: token)
		headers["Accept"] = "application/json"
		guard let (data, response) = try? await GFNHTTP.send(parts.url!, headers: headers),
			  response.statusCode == 200 else { return nil }
		return GFNHTTP.string(GFNHTTP.json(data)["membershipTier"])
	}

	private static func jwtClaims(_ token: String) -> [String: Any] {
		let parts = token.split(separator: ".")
		guard parts.count >= 2 else { return [:] }
		var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		while payload.count % 4 != 0 { payload += "=" }
		guard let data = Data(base64Encoded: payload) else { return [:] }
		return GFNHTTP.json(data)
	}
}

// MARK: - Web sign-in

@MainActor
private final class GFNWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
	private var session: ASWebAuthenticationSession?

	func run(url: URL) async throws -> URL {
		try await withCheckedThrowingContinuation { continuation in
			let session = ASWebAuthenticationSession(url: url, callbackURLScheme: GFNConstants.callbackScheme) { callback, error in
				if let callback {
					continuation.resume(returning: callback)
				} else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
					continuation.resume(throwing: GFNError.signInCancelled)
				} else {
					continuation.resume(throwing: error ?? GFNError.signInCancelled)
				}
			}
			session.presentationContextProvider = self
			self.session = session
			if !session.start() {
				continuation.resume(throwing: GFNError.server("Couldn't open the sign-in page."))
			}
		}
	}

	nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
		MainActor.assumeIsolated {
			let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
			let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
			return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
		}
	}
}

/// NVIDIA redirects to http://localhost:2259. This listener answers that request with a 302 to
/// `iplaynow://callback?…`, which ASWebAuthenticationSession is waiting for.
private final class GFNLoopbackRedirect: @unchecked Sendable {
	private let queue = DispatchQueue(label: "dev.reefbarman.iplaynow.signin")
	private var listener: NWListener?

	func start() throws {
		let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: GFNConstants.redirectPort)!)
		listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
		listener.start(queue: queue)
		self.listener = listener
	}

	func stop() {
		listener?.cancel()
		listener = nil
	}

	private func handle(_ connection: NWConnection) {
		connection.start(queue: queue)
		connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
			let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
			let path = text.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
			let query = URLComponents(string: "http://localhost\(path)")?.queryItems ?? []
			let reply: String
			if query.contains(where: { ($0.name == "code" || $0.name == "error") && !($0.value ?? "").isEmpty }) {
				var target = URLComponents()
				target.scheme = GFNConstants.callbackScheme
				target.host = "callback"
				target.queryItems = query
				reply = "HTTP/1.1 302 Found\r\nLocation: \(target.url?.absoluteString ?? "\(GFNConstants.callbackScheme)://callback")\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			} else {
				reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			}
			connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
		}
	}
}
