import Foundation

/// CloudMatch: GeForce NOW's session service. Creates, polls, lists and stops sessions.
enum GFNSessions {
	// MARK: - Create

	static func create(token: String, provider: GFNProvider, game: GFNGame, variant: GFNGameVariant,
					   request: GFNStreamRequest) async throws -> GFNSession {
		let base = baseURL(provider.streamingURL)
		var parts = URLComponents(url: base.appending(path: "v2/session"), resolvingAgainstBaseURL: false)!
		parts.queryItems = [
			.init(name: "keyboardLayout", value: request.keyboardLayout),
			.init(name: "languageCode", value: request.language),
		]
		let clientID = UUID().uuidString
		let body = try JSONSerialization.data(withJSONObject: sessionBody(game: game, variant: variant, request: request))
		let (data, response) = try await GFNHTTP.send(parts.url!, method: "POST",
			headers: GFNHTTP.cloudMatchHeaders(token: token, clientID: clientID, deviceID: GFNDevice.id, includeOrigin: true),
			body: body, timeout: 30)
		let json = GFNHTTP.json(data)
		if isSessionLimit(json) {
			throw GFNError.sessionLimit(remoteSessions(json["otherUserSessions"] as? [[String: Any]] ?? []))
		}
		if response.statusCode == 401 { throw GFNError.notSignedIn }
		let status = json["requestStatus"] as? [String: Any]
		guard response.statusCode == 200, GFNHTTP.int(status?["statusCode"]) == 1,
			  let object = json["session"] as? [String: Any] else {
			throw GFNError.server(GFNHTTP.message(data, fallback: "GeForce NOW couldn't start the game."))
		}
		return parse(object, base: base, clientID: clientID, deviceID: GFNDevice.id, fallbackAppID: variant.id)
	}

	/// An NVST-shaped request. Without `secureRTSPSupported` and streamer version 14 the rig never
	/// provisions the RTSPS endpoint NVST needs.
	private static func sessionBody(game: GFNGame, variant: GFNGameVariant, request: GFNStreamRequest) -> [String: Any] {
		let metadata: [[String: String]] = [
			["key": "SubSessionId", "value": UUID().uuidString],
			["key": "wssignaling", "value": "1"],
			["key": "networkType", "value": "Unknown"],
			["key": "ClientImeSupport", "value": "0"],
			["key": "preferredLauncher", "value": variant.store],
			["key": "clientPhysicalResolution", "value": "{\"horizontalPixels\":\(request.width),\"verticalPixels\":\(request.height)}"],
			["key": "surroundAudioInfo", "value": "2"],
		]
		return ["sessionRequestData": [
			"appId": variant.id,
			"internalTitle": game.title,
			"availableSupportedControllers": [2],
			"networkTestSessionId": NSNull(),
			"parentSessionId": NSNull(),
			"clientIdentification": "GFN-PC",
			"deviceHashId": GFNDevice.id,
			"clientVersion": "30.0",
			"sdkVersion": "2.0",
			"streamerVersion": "14",
			"clientPlatformName": "windows",
			"clientRequestMonitorSettings": [[
				"monitorId": 0,
				"positionX": 0,
				"positionY": 0,
				"widthInPixels": request.width,
				"heightInPixels": request.height,
				"framesPerSecond": request.fps,
				"sdrHdrMode": 0,
				"displayData": NSNull(),
				"hdr10PlusGamingData": NSNull(),
				"dpi": 100,
			]],
			"useOps": true,
			"audioMode": 2,
			"metaData": metadata,
			"sdrHdrMode": 0,
			"clientDisplayHdrCapabilities": NSNull(),
			"surroundAudioInfo": 0,
			"remoteControllersBitmap": 1,
			"clientTimezoneOffset": TimeZone.current.secondsFromGMT() * 1000,
			"enhancedStreamMode": 0,
			"requestedAudioFormat": 0,
			"transport": NSNull(),
			"appLaunchMode": 2,
			"secureRTSPSupported": true,
			"partnerCustomData": "",
			"accountLinked": true,
			"enablePersistingInGameSettings": true,
			"userAge": 26,
			"requestedStreamingFeatures": [
				"reflex": request.fps >= 120,
				"bitDepth": 0,
				"trueHdr": false,
				"enabledL4S": false,
				"supportedHidDevices": 0,
				"profile": 0,
				"fallbackToLogicalResolution": false,
				"chromaFormat": 0,
				"prefilterMode": 0,
				"prefilterSharpness": 0,
				"prefilterNoiseReduction": 0,
				"hudStreamingMode": 0,
			] as [String: Any],
		] as [String: Any]]
	}

	// MARK: - Poll

	static func poll(token: String, _ session: GFNSession) async throws -> GFNSession {
		let primary = pollBase(session)
		let polled = try await poll(token: token, session, base: primary)
		// On NVIDIA's own servers a ready rig owns its connection details; ask it directly.
		// It may still be warming up, so keep the queue's answer if it doesn't reply yet.
		if let direct = readyDetailsBase(polled), direct != primary {
			do {
				return try await poll(token: token, polled, base: direct)
			} catch let error as GFNError {
				throw error
			} catch {}
		}
		return polled
	}

	private static func poll(token: String, _ session: GFNSession, base: URL) async throws -> GFNSession {
		let url = base.appending(path: "v2/session/\(session.id)")
		let (data, response) = try await GFNHTTP.send(url,
			headers: GFNHTTP.cloudMatchHeaders(token: token, clientID: session.clientID, deviceID: session.deviceID, includeOrigin: false))
		let json = GFNHTTP.json(data)
		let status = json["requestStatus"] as? [String: Any]
		if isAbandoned(status) { throw GFNError.queueAbandoned }
		if response.statusCode == 401 { throw GFNError.notSignedIn }
		if response.statusCode == 404 || response.statusCode == 410 {
			throw GFNError.sessionEnded("The GeForce NOW session has ended.")
		}
		guard response.statusCode == 200, GFNHTTP.int(status?["statusCode"]) == 1,
			  let object = json["session"] as? [String: Any],
			  let state = GFNHTTP.int(object["status"]), state > 0 else {
			throw URLError(.badServerResponse)
		}
		if state > 3 && state != 6 { throw GFNError.sessionEnded("The GeForce NOW session has ended.") }
		var updated = parse(object, base: session.baseURL, clientID: session.clientID, deviceID: session.deviceID, fallbackAppID: session.appID)
		if updated.rtspsEndpoints.isEmpty { updated.rtspsEndpoints = session.rtspsEndpoints }
		if updated.serverHost == nil { updated.serverHost = session.serverHost }
		return updated
	}

	// MARK: - List and stop

	/// Sessions the account already has queued, ready or streaming on this provider
	static func active(token: String, provider: GFNProvider) async throws -> [GFNRemoteSession] {
		let url = baseURL(provider.streamingURL).appending(path: "v2/session")
		let (data, response) = try await GFNHTTP.send(url,
			headers: GFNHTTP.cloudMatchHeaders(token: token, clientID: UUID().uuidString, deviceID: GFNDevice.id, includeOrigin: false))
		if response.statusCode == 401 { throw GFNError.notSignedIn }
		let json = GFNHTTP.json(data)
		let status = json["requestStatus"] as? [String: Any]
		guard response.statusCode == 200, GFNHTTP.int(status?["statusCode"]) == 1 else {
			throw GFNError.server(GFNHTTP.message(data, fallback: "Couldn't check for running sessions."))
		}
		return remoteSessions(json["sessions"] as? [[String: Any]] ?? [])
	}

	static func stop(token: String, _ session: GFNSession) async throws {
		let url = pollBase(session).appending(path: "v2/session/\(session.id)")
		try await delete(url, token: token, clientID: session.clientID, deviceID: session.deviceID)
	}

	static func stop(token: String, _ remote: GFNRemoteSession, provider: GFNProvider) async throws {
		let base = remote.controlBaseURL
			?? remote.serverHost.flatMap { URL(string: "https://\($0)/") }
			?? baseURL(provider.streamingURL)
		try await delete(base.appending(path: "v2/session/\(remote.id)"), token: token, clientID: UUID().uuidString, deviceID: GFNDevice.id)
	}

	private static func delete(_ url: URL, token: String, clientID: String, deviceID: String) async throws {
		let (data, response) = try await GFNHTTP.send(url, method: "DELETE",
			headers: GFNHTTP.cloudMatchHeaders(token: token, clientID: clientID, deviceID: deviceID, includeOrigin: false))
		guard [200, 204, 404, 410].contains(response.statusCode) else {
			throw GFNError.server(GFNHTTP.message(data, fallback: "Couldn't end the GeForce NOW session."))
		}
	}

	// MARK: - Parsing

	static func parse(_ object: [String: Any], base: URL, clientID: String, deviceID: String, fallbackAppID: String) -> GFNSession {
		let host = serverHost(object)
		return GFNSession(
			id: GFNHTTP.string(object["sessionId"]) ?? UUID().uuidString,
			appID: appID(object) ?? fallbackAppID,
			status: GFNHTTP.int(object["status"]) ?? 1,
			queuePosition: queuePosition(object),
			seatSetupStep: GFNHTTP.int((object["seatSetupInfo"] as? [String: Any])?["seatSetupStep"]),
			rtspsEndpoints: rtspsEndpoints(object, fallbackHost: host),
			baseURL: base,
			controlBaseURL: controlBaseURL(object["sessionControlInfo"] as? [String: Any]),
			serverHost: host,
			clientID: clientID,
			deviceID: deviceID
		)
	}

	private static func remoteSessions(_ items: [[String: Any]]) -> [GFNRemoteSession] {
		items.compactMap { item in
			guard let id = GFNHTTP.string(item["sessionId"]),
				  let status = GFNHTTP.int(item["status"]), (1...3).contains(status) else { return nil }
			return GFNRemoteSession(id: id, appID: appID(item) ?? "", title: nil, status: status,
				controlBaseURL: controlBaseURL(item["sessionControlInfo"] as? [String: Any]),
				serverHost: serverHost(item))
		}
	}

	private static func appID(_ object: [String: Any]) -> String? {
		let value = (object["sessionRequestData"] as? [String: Any])?["appId"]
		return GFNHTTP.string(value) ?? GFNHTTP.int(value).map(String.init)
	}

	private static func queuePosition(_ object: [String: Any]) -> Int? {
		let candidates: [Any?] = [
			object["queuePosition"],
			(object["seatSetupInfo"] as? [String: Any])?["queuePosition"],
			(object["sessionProgress"] as? [String: Any])?["queuePosition"],
			(object["progressInfo"] as? [String: Any])?["queuePosition"],
		]
		return candidates.lazy.compactMap { GFNHTTP.int($0) }.first { $0 > 0 }
	}

	/// The rig's host: the usage-14 connection, else any connection, else the control host
	private static func serverHost(_ object: [String: Any]) -> String? {
		let connections = object["connectionInfo"] as? [[String: Any]] ?? []
		if let main = connections.first(where: { GFNHTTP.int($0["usage"]) == 14 }),
		   let host = endpointHost(main["ip"]) ?? endpointHost(main["resourcePath"]) {
			return host
		}
		if let host = connections.lazy.compactMap({ endpointHost($0["ip"]) }).first { return host }
		return endpointHost((object["sessionControlInfo"] as? [String: Any])?["ip"])
	}

	private static func endpointHost(_ value: Any?) -> String? {
		guard var text = GFNHTTP.string(value) else { return nil }
		if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
		text = String(text.prefix { $0 != "/" && $0 != "?" })
		if let colon = text.lastIndex(of: ":"), !text.contains("]") { text = String(text[..<colon]) }
		text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
		return text.isEmpty || text == "0.0.0.0" ? nil : text
	}

	/// RTSPS control endpoints: tagged entries on :322 first, then untagged :322, then tagged
	/// entries on other ports. No guessed fallback.
	static func rtspsEndpoints(_ object: [String: Any], fallbackHost: String?) -> [String] {
		var preferred: [String] = [], untagged: [String] = [], otherPort: [String] = []
		var seen = Set<String>()
		for connection in object["connectionInfo"] as? [[String: Any]] ?? [] {
			let resource = GFNHTTP.string(connection["resourcePath"]) ?? ""
			if resource.lowercased().hasPrefix("rtsps://") || resource.lowercased().hasPrefix("rtsp://") {
				if seen.insert(resource).inserted { preferred.append(resource) }
				continue
			}
			let tagged = GFNHTTP.int(connection["usage"]) == 16 || GFNHTTP.int(connection["appLevelProtocol"]) == 6
			let port = GFNHTTP.int(connection["port"]) ?? 0
			guard tagged || port == 322, port > 0 else { continue }
			let ip = GFNHTTP.string(connection["ip"])
			guard let host = ip == "0.0.0.0" ? fallbackHost : (ip ?? fallbackHost) else { continue }
			let endpoint = "rtsps://\(host):\(port)"
			guard seen.insert(endpoint).inserted else { continue }
			switch (tagged, port == 322) {
			case (true, true): preferred.append(endpoint)
			case (true, false): otherPort.append(endpoint)
			default: untagged.append(endpoint)
			}
		}
		return preferred + untagged + otherPort
	}

	// MARK: - Routing

	private static func baseURL(_ url: URL) -> URL {
		url.absoluteString.hasSuffix("/") ? url : url.appending(path: "")
	}

	private static func isNVIDIAHost(_ url: URL) -> Bool {
		let host = url.host?.lowercased() ?? ""
		return host.hasSuffix(".cloudmatchbeta.nvidiagrid.net") || host.hasSuffix(".cloudmatch.nvidiagrid.net")
	}

	/// CloudMatch names a queue host like `np-…-….cloudmatch.nvidiagrid.net`; accept only that shape
	private static func controlBaseURL(_ control: [String: Any]?) -> URL? {
		let port = GFNHTTP.int(control?["port"])
		guard port == nil || port == 443, let host = endpointHost(control?["ip"]),
			  host.range(of: #"^np-[a-z0-9]+(?:-[a-z0-9]+)+\.(?:cloudmatchbeta|cloudmatch)\.nvidiagrid\.net$"#, options: .regularExpression) != nil
		else { return nil }
		return URL(string: "https://\(host)/")
	}

	/// Partner servers keep polling where the session was created; NVIDIA's move to the queue host
	private static func pollBase(_ session: GFNSession) -> URL {
		guard isNVIDIAHost(session.baseURL), let control = session.controlBaseURL else { return session.baseURL }
		return control
	}

	private static func readyDetailsBase(_ session: GFNSession) -> URL? {
		guard session.status == 2 || session.status == 3, isNVIDIAHost(session.baseURL),
			  let server = session.serverHost, !server.contains("nvidiagrid.net") else { return nil }
		return URL(string: "https://\(server)/")
	}

	private static func isSessionLimit(_ json: [String: Any]) -> Bool {
		let status = json["requestStatus"] as? [String: Any] ?? json
		let description = (GFNHTTP.string(status["statusDescription"]) ?? "").uppercased()
		return GFNHTTP.int(status["statusCode"]) == 11
			|| GFNHTTP.int(status["unifiedErrorCode"]) == 0x4AF1_201A
			|| description.hasPrefix("SESSION_LIMIT_EXCEEDED")
	}

	private static func isAbandoned(_ status: [String: Any]?) -> Bool {
		let description = (GFNHTTP.string(status?["statusDescription"]) ?? "").uppercased()
		let unified = (GFNHTTP.string(status?["unifiedErrorCode"]) ?? "").uppercased()
		return GFNHTTP.int(status?["statusCode"]) == 69
			|| description.contains("SESSION_REQUEST_IN_QUEUE_ABANDONED")
			|| unified == "4A8C300F"
	}
}
