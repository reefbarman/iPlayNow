import Foundation
import Observation
import Security

/// The signed-in GeForce NOW account, kept in the Keychain.
@MainActor @Observable
final class GFNAccountStore {
	private(set) var account: GFNAccount?
	/// Sign-in providers, NVIDIA first until the live list loads
	private(set) var providers: [GFNProvider] = [.nvidia]

	private var refreshing: Task<GFNAccount, Error>?
	private static let lastProviderKey = "iplaygfn.lastProvider"

	init() {
		account = Keychain.load()
		if let account, account.provider != .nvidia { providers.append(account.provider) }
	}

	/// The provider to offer first: the last one used, else NVIDIA
	var preferredProvider: GFNProvider {
		let id = account?.provider.id ?? UserDefaults.standard.string(forKey: Self.lastProviderKey)
		return providers.first { $0.id == id } ?? providers.first ?? .nvidia
	}

	func loadProviders() async {
		let loaded = await GFNAuth.providers()
		if !loaded.isEmpty { providers = loaded }
	}

	func signIn(with provider: GFNProvider) async throws {
		UserDefaults.standard.set(provider.id, forKey: Self.lastProviderKey)
		let signedIn = try await GFNAuth.signIn(with: provider)
		account = signedIn
		Keychain.save(signedIn)
	}

	func signOut() {
		refreshing?.cancel()
		refreshing = nil
		account = nil
		Keychain.delete()
	}

	/// A token for GeForce NOW's APIs, refreshed first if it's close to expiring.
	/// Signs out if NVIDIA no longer accepts the saved sign-in.
	func accessToken() async throws -> String {
		guard let account else { throw GFNError.notSignedIn }
		if let refreshing { return try await refreshing.value.tokens.apiToken }
		guard Date() >= account.tokens.expiresAt.addingTimeInterval(-600) else { return account.tokens.apiToken }
		let task = Task { try await GFNAuth.refreshed(account) }
		refreshing = task
		defer { refreshing = nil }
		do {
			let updated = try await task.value
			guard self.account?.userID == updated.userID else { throw GFNError.notSignedIn }
			self.account = updated
			Keychain.save(updated)
			return updated.tokens.apiToken
		} catch GFNError.notSignedIn {
			signOut()
			throw GFNError.notSignedIn
		}
	}

	/// Refreshes the membership tier shown in Settings
	func refreshTier() async {
		guard let account, let token = try? await accessToken(),
			  let tier = await GFNAuth.membershipTier(token: token, userID: account.userID, provider: account.provider),
			  self.account?.userID == account.userID else { return }
		self.account?.tier = tier
		if let updated = self.account { Keychain.save(updated) }
	}
}

private enum Keychain {
	private static let query: [String: Any] = [
		kSecClass as String: kSecClassGenericPassword,
		kSecAttrService as String: GFNConstants.keychainService,
		kSecAttrAccount as String: "account",
	]

	static func load() -> GFNAccount? {
		var search = query
		search[kSecReturnData as String] = true
		search[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
			  let data = result as? Data else { return nil }
		return try? JSONDecoder().decode(GFNAccount.self, from: data)
	}

	static func save(_ account: GFNAccount) {
		guard let data = try? JSONEncoder().encode(account) else { return }
		let update: [String: Any] = [
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
		]
		if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
			SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
		}
	}

	static func delete() {
		SecItemDelete(query as CFDictionary)
	}
}
