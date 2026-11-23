import Foundation

/// The games the account owns, from GeForce NOW's GraphQL catalogue.
enum GFNLibrary {
	private static let query = """
	query OwnedGames($vpcId: String!, $cursor: String!, $filters: AppFilterFields!, $sort: String!) {
	  apps(vpcId: $vpcId, language: "en_US", orderBy: $sort, first: 250, after: $cursor, filters: $filters) {
	    pageInfo { hasNextPage endCursor }
	    items {
	      id title genres
	      images { GAME_BOX_ART TV_BANNER HERO_IMAGE }
	      variants { id appStore gfn { library { status lastPlayedDate } } }
	    }
	  }
	}
	"""

	@MainActor
	static func ownedGames(accounts: GFNAccountStore) async throws -> [GFNGame] {
		guard let provider = accounts.account?.provider else { throw GFNError.notSignedIn }
		let token = try await accounts.accessToken()
		let vpcID = await GFNServerInfo.vpcID(token: token, provider: provider) ?? "GFN-PC"
		let games = try await fetch(token: token, vpcID: vpcID)
		save(games)
		return games
	}

	private static func fetch(token: String, vpcID: String) async throws -> [GFNGame] {
		var headers = GFNHTTP.desktopHeaders(token: token)
		headers["Content-Type"] = "application/json"
		var cursor = ""
		var seenCursors = Set<String>()
		var seenGames = Set<String>()
		var games: [GFNGame] = []
		for _ in 0..<40 {
			try Task.checkCancellation()
			let body = try JSONSerialization.data(withJSONObject: [
				"query": query,
				"variables": [
					"vpcId": vpcID,
					"cursor": cursor,
					"filters": ["variants": ["gfn": ["library": ["status": ["notEquals": "NOT_OWNED"]]]]],
					"sort": "variants.gfn.library.lastPlayedDate:DESC,computedValues.libraryAddedDate:DESC,sortName:ASC",
				] as [String: Any],
			] as [String: Any])
			let (data, response) = try await GFNHTTP.send(GFNConstants.graphQLURL, method: "POST", headers: headers, body: body, timeout: 30)
			let payload = GFNHTTP.json(data)
			guard response.statusCode == 200, payload["errors"] == nil,
				  let apps = (payload["data"] as? [String: Any])?["apps"] as? [String: Any],
				  let items = apps["items"] as? [[String: Any]] else {
				if response.statusCode == 401 { throw GFNError.notSignedIn }
				throw GFNError.server("Couldn't load your games. Pull to refresh to try again.")
			}
			for item in items {
				guard let game = parse(item), seenGames.insert(game.id).inserted else { continue }
				games.append(game)
			}
			let page = apps["pageInfo"] as? [String: Any]
			guard page?["hasNextPage"] as? Bool == true,
				  let next = GFNHTTP.string(page?["endCursor"]), next != cursor,
				  seenCursors.insert(next).inserted else { break }
			cursor = next
		}
		return games.filter { !$0.ownedVariants.isEmpty }
	}

	static func parse(_ item: [String: Any]) -> GFNGame? {
		guard let id = GFNHTTP.string(item["id"]), let title = GFNHTTP.string(item["title"]) else { return nil }
		let images = item["images"] as? [String: Any]
		func image(_ keys: String...) -> URL? {
			keys.lazy.compactMap { GFNHTTP.string(images?[$0]) }.compactMap(URL.init(string:)).first
		}
		var lastPlayed: Date?
		var variants: [GFNGameVariant] = []
		for variant in item["variants"] as? [[String: Any]] ?? [] {
			// CloudMatch launches by the numeric variant id
			guard let variantID = GFNHTTP.string(variant["id"]), Int(variantID) != nil,
				  !variants.contains(where: { $0.id == variantID }) else { continue }
			let store = GFNHTTP.string(variant["appStore"])?.uppercased() ?? "NONE"
			let library = (variant["gfn"] as? [String: Any])?["library"] as? [String: Any]
			let status = GFNHTTP.string(library?["status"])?.uppercased() ?? ""
			if let played = parseDate(library?["lastPlayedDate"]) {
				lastPlayed = max(lastPlayed ?? played, played)
			}
			variants.append(GFNGameVariant(
				id: variantID,
				store: store,
				storeName: GFNGameVariant.storeName(for: store),
				// Seen values: MANUAL, PLATFORM_SYNC, IN_LIBRARY. Treat anything else that isn't
				// NOT_OWNED as owned too, matching the query's own filter.
				isOwned: !status.isEmpty && status != "NOT_OWNED"
			))
		}
		return GFNGame(
			id: id,
			title: title,
			boxArtURL: image("GAME_BOX_ART", "TV_BANNER", "HERO_IMAGE"),
			heroURL: image("HERO_IMAGE", "TV_BANNER", "GAME_BOX_ART"),
			genres: (item["genres"] as? [String]) ?? [],
			lastPlayed: lastPlayed,
			variants: variants
		)
	}

	private static func parseDate(_ value: Any?) -> Date? {
		guard let text = GFNHTTP.string(value) else { return nil }
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		if let date = formatter.date(from: text) { return date }
		formatter.formatOptions = [.withInternetDateTime]
		if let date = formatter.date(from: text) { return date }
		if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds) }
		return nil
	}

	// MARK: - Cache

	private static var cacheURL: URL {
		URL.applicationSupportDirectory.appending(path: "library.json")
	}

	/// The last library loaded, so the home screen can show it straight away
	static func cached() -> [GFNGame] {
		guard let data = try? Data(contentsOf: cacheURL) else { return [] }
		return (try? JSONDecoder().decode([GFNGame].self, from: data)) ?? []
	}

	static func save(_ games: [GFNGame]) {
		try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
		if let data = try? JSONEncoder().encode(games) { try? data.write(to: cacheURL, options: .atomic) }
	}

	static func clearCache() {
		try? FileManager.default.removeItem(at: cacheURL)
	}
}
