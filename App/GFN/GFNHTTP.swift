import CryptoKit
import Foundation

/// Small HTTP and JSON helpers shared by the GeForce NOW clients.
enum GFNHTTP {
	private static let session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 20
		config.httpCookieStorage = nil
		return URLSession(configuration: config)
	}()

	@discardableResult
	static func send(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
					 timeout: TimeInterval = 20) async throws -> (Data, HTTPURLResponse) {
		var request = URLRequest(url: url, timeoutInterval: timeout)
		request.httpMethod = method
		request.httpBody = body
		for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw GFNError.server("GeForce NOW sent an unexpected response.")
		}
		return (data, http)
	}

	static func json(_ data: Data) -> [String: Any] {
		(try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
	}

	static func formBody(_ fields: [String: String]) -> Data {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		return fields
			.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
			.joined(separator: "&")
			.data(using: .utf8) ?? Data()
	}

	/// Integers arrive as numbers or strings; booleans are not integers
	static func int(_ value: Any?) -> Int? {
		if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
		return number.intValue
	}

	static func string(_ value: Any?) -> String? {
		guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
		return text
	}

	/// A short readable reason from an error response body
	static func message(_ data: Data, fallback: String) -> String {
		let body = json(data)
		let status = body["requestStatus"] as? [String: Any]
		return string(status?["statusDescription"])
			?? string(body["error_description"])
			?? string(body["message"])
			?? fallback
	}

	// MARK: - Headers

	static var oauthHeaders: [String: String] {
		[
			"Origin": "https://nvfile",
			"Referer": "https://nvfile/",
			"Accept": "application/json, text/plain, */*",
			"User-Agent": GFNConstants.userAgent,
		]
	}

	/// GraphQL, server info and subscriptions identify as the desktop client
	static func desktopHeaders(token: String) -> [String: String] {
		[
			"Accept": "application/json, text/plain, */*",
			"Origin": "https://play.geforcenow.com",
			"Referer": "https://play.geforcenow.com/",
			"Authorization": "GFNJWT \(token)",
			"nv-client-id": GFNConstants.lcarsClientID,
			"nv-client-type": "NATIVE",
			"nv-client-version": GFNConstants.clientVersion,
			"nv-client-streamer": "NVIDIA-CLASSIC",
			"nv-device-os": "WINDOWS",
			"nv-device-type": "DESKTOP",
			"nv-browser-type": "CHROME",
			"User-Agent": GFNConstants.userAgent,
		]
	}

	static func cloudMatchHeaders(token: String, clientID: String, deviceID: String, includeOrigin: Bool) -> [String: String] {
		var headers = [
			"User-Agent": GFNConstants.userAgent,
			"Authorization": "GFNJWT \(token)",
			"Content-Type": "application/json",
			"nv-browser-type": "CHROME",
			"nv-client-id": clientID,
			"nv-client-streamer": "NVIDIA-CLASSIC",
			"nv-client-type": "NATIVE",
			"nv-client-version": GFNConstants.clientVersion,
			"nv-device-make": "APPLE",
			"nv-device-model": "iOS",
			"nv-device-os": "WINDOWS",
			"nv-device-type": "DESKTOP",
			"x-device-id": deviceID,
		]
		if includeOrigin {
			headers["Origin"] = "https://play.geforcenow.com"
			headers["Referer"] = "https://play.geforcenow.com/"
		}
		return headers
	}
}

/// This install's stable device id: SHA-256 hex of a UUID made once.
enum GFNDevice {
	static let id: String = {
		let key = "iplaynow.deviceId"
		if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
		let digest = SHA256.hash(data: Data(UUID().uuidString.utf8))
		let id = digest.map { String(format: "%02x", $0) }.joined()
		UserDefaults.standard.set(id, forKey: key)
		return id
	}()
}

/// Server info for a provider: the vpc id the catalogue and subscriptions are keyed by.
enum GFNServerInfo {
	static func vpcID(token: String, provider: GFNProvider) async -> String? {
		let url = provider.streamingURL.appending(path: "v2/serverInfo")
		var headers = GFNHTTP.desktopHeaders(token: token)
		headers["nv-client-type"] = "BROWSER"
		headers["nv-client-streamer"] = "WEBRTC"
		guard let (data, response) = try? await GFNHTTP.send(url, headers: headers),
			  response.statusCode == 200 else { return nil }
		let status = GFNHTTP.json(data)["requestStatus"] as? [String: Any]
		return GFNHTTP.string(status?["serverId"])
	}
}
