import Foundation

/// Fixed values GeForce NOW's own PC client sends. They identify us as that client, so change
/// them together and only on evidence.
enum GFNConstants {
	static let clientID = "ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ"
	static let scopes = "openid consent email tk_client age"
	static let lcarsClientID = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
	static let clientVersion = "2.0.88.129"
	static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.88.129"

	static let authorizeURL = URL(string: "https://login.nvidia.com/authorize")!
	static let tokenURL = URL(string: "https://login.nvidia.com/token")!
	static let userInfoURL = URL(string: "https://login.nvidia.com/userinfo")!
	static let clientTokenURL = URL(string: "https://login.nvidia.com/client_token")!
	static let serviceURLs = URL(string: "https://pcs.geforcenow.com/v1/serviceUrls")!
	static let subscriptionsURL = URL(string: "https://mes.geforcenow.com/v4/subscriptions")!
	static let graphQLURL = URL(string: "https://games.geforce.com/graphql")!

	/// NVIDIA's registered redirect is a loopback address; a local listener bounces it to our scheme.
	static let redirectURI = "http://localhost:2259"
	static let redirectPort: UInt16 = 2259
	static let callbackScheme = "iplaynow"

	static let keychainService = "dev.reefbarman.iplaynow.auth"
}

/// A sign-in provider: NVIDIA itself or an alliance partner with its own CloudMatch servers.
struct GFNProvider: Codable, Hashable, Identifiable {
	/// NVIDIA's identity provider id, sent as `idp_id` when signing in
	var id: String
	var code: String
	var name: String
	/// CloudMatch base for this provider: server info, session create and the session list
	var streamingURL: URL

	/// What players know it as: Pentanet runs GeForce NOW in Australia as Cloud.GG
	var displayName: String {
		let key = (code + " " + name).uppercased()
		return key.contains("PENTANET") || key.contains("CLOUDGG") || key.contains("CLOUD.GG") ? "Cloud.GG" : name
	}

	static let nvidia = GFNProvider(
		id: "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg",
		code: "NVIDIA",
		name: "NVIDIA",
		streamingURL: URL(string: "https://prod.cloudmatchbeta.nvidiagrid.net/")!
	)
}

struct GFNTokens: Codable, Hashable {
	var accessToken: String
	var refreshToken: String?
	var idToken: String?
	var expiresAt: Date
	var clientToken: String?
	var clientTokenExpiresAt: Date?

	/// What GeForce NOW's APIs authenticate with (`Authorization: GFNJWT …`)
	var apiToken: String { idToken ?? accessToken }
}

struct GFNAccount: Codable, Hashable {
	var provider: GFNProvider
	var userID: String
	var displayName: String
	var email: String?
	var tier: String?
	var tokens: GFNTokens

	/// "ULTIMATE" → "Ultimate"
	var tierName: String? {
		guard let tier, !tier.isEmpty else { return nil }
		return tier.replacingOccurrences(of: "_", with: " ").capitalized
	}
}

/// One store's copy of a game. The id is what CloudMatch launches.
struct GFNGameVariant: Identifiable, Codable, Hashable {
	var id: String
	/// "STEAM", "EPIC", "GOG", "XBOX", …
	var store: String
	var storeName: String
	var isOwned: Bool
	/// GeForce NOW runs this copy with ray tracing / HDR
	var rtx = false
	var hdr = false

	/// Launch priority when a game is owned on several stores: Steam, Epic, GOG, Xbox, then the rest
	var storeRank: Int {
		switch store.uppercased() {
		case "STEAM": 0
		case "EPIC", "EGS", "EPIC_GAMES_STORE": 1
		case "GOG", "GOG_COM": 2
		case "XBOX", "XBOX_GAME_PASS", "GAME_PASS", "MICROSOFT", "MICROSOFT_STORE": 3
		default: 4
		}
	}

	static func storeName(for store: String) -> String {
		switch store.uppercased() {
		case "STEAM": "Steam"
		case "EPIC", "EGS", "EPIC_GAMES_STORE": "Epic Games"
		case "GOG", "GOG_COM": "GOG"
		case "XBOX", "XBOX_GAME_PASS", "GAME_PASS": "Xbox"
		case "MICROSOFT", "MICROSOFT_STORE": "Microsoft Store"
		case "UPLAY", "UBISOFT", "UBISOFT_CONNECT": "Ubisoft Connect"
		case "EA", "EA_APP", "ORIGIN": "EA app"
		case "BATTLENET", "BATTLE_NET", "BLIZZARD": "Battle.net"
		case "", "NONE", "AUTO": "GeForce NOW"
		default: store.replacingOccurrences(of: "_", with: " ").capitalized
		}
	}
}

struct GFNGame: Identifiable, Codable, Hashable {
	var id: String
	var title: String
	var boxArtURL: URL?
	var heroURL: URL?
	var genres: [String]
	var lastPlayed: Date?
	var variants: [GFNGameVariant]

	/// Owned variants in launch priority order, keeping catalogue order within a rank
	var ownedVariants: [GFNGameVariant] {
		variants.enumerated()
			.filter { $0.element.isOwned }
			.sorted { ($0.element.storeRank, $0.offset) < ($1.element.storeRank, $1.offset) }
			.map(\.element)
	}

	/// Tags for the cover, from any copy you own
	var supportsRTX: Bool { ownedVariants.contains(where: \.rtx) }
	var supportsHDR: Bool { ownedVariants.contains(where: \.hdr) }
}

extension GFNGameVariant {
	// Libraries cached before the tags existed have no rtx/hdr keys
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		store = try c.decode(String.self, forKey: .store)
		storeName = try c.decode(String.self, forKey: .storeName)
		isOwned = try c.decode(Bool.self, forKey: .isOwned)
		rtx = try c.decodeIfPresent(Bool.self, forKey: .rtx) ?? false
		hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? false
	}
}

struct GFNStreamRequest: Hashable {
	var width: Int
	var height: Int
	var fps: Int
	/// 10-bit HDR10. Needs HEVC, and the game and membership have to support it.
	var hdr = false
	var keyboardLayout = "en-US"
	var language = "en_US"
}

/// One CloudMatch session as seen while launching.
struct GFNSession: Identifiable, Hashable {
	var id: String
	var appID: String
	/// 1 queued or setting up, 2 rig ready, 3 streaming
	var status: Int
	var queuePosition: Int?
	var seatSetupStep: Int?
	var rtspsEndpoints: [String]
	/// Where the session was created
	var baseURL: URL
	/// The queue's own control host on NVIDIA's servers, when CloudMatch names one
	var controlBaseURL: URL?
	/// The rig's address once one is assigned
	var serverHost: String?
	/// `nv-client-id` for this session; poll and stop must reuse it
	var clientID: String
	var deviceID: String
}

/// A session the account already has running or queued somewhere.
struct GFNRemoteSession: Identifiable, Hashable {
	var id: String
	var appID: String
	var title: String?
	var status: Int
	var controlBaseURL: URL?
	var serverHost: String?

	var statusText: String {
		switch status {
		case 1: "Waiting in queue"
		case 2: "Ready"
		default: "Playing"
		}
	}
}

enum GFNError: LocalizedError {
	case signInCancelled
	case notSignedIn
	case sessionLimit([GFNRemoteSession])
	case queueAbandoned
	case sessionEnded(String)
	case server(String)

	var errorDescription: String? {
		switch self {
		case .signInCancelled: "Sign-in was cancelled."
		case .notSignedIn: "Sign in to GeForce NOW to continue."
		case .sessionLimit: "Another GeForce NOW session is already running on this account."
		case .queueAbandoned: "GeForce NOW dropped this place in the queue. Try launching the game again."
		case .sessionEnded(let reason): reason
		case .server(let message): message
		}
	}
}
