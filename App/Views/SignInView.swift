import SwiftUI

/// Sign in to GeForce NOW, through NVIDIA or an alliance partner
struct SignInView: View {
	@Environment(GFNAccountStore.self) private var accounts
	@State private var provider: GFNProvider?
	@State private var signingIn = false
	@State private var error: String?

	private var selected: GFNProvider { provider ?? accounts.preferredProvider }

	var body: some View {
		NavigationStack {
			Form {
				Section {
					VStack(spacing: 12) {
						Image(systemName: "cloud.fill")
							.font(.system(size: 48))
							.foregroundStyle(.green)
						Text("Play your GeForce NOW games")
							.font(.title2.bold())
							.multilineTextAlignment(.center)
						Text("Sign in with your GeForce NOW account. Your games show up once you've linked their stores in GeForce NOW.")
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 12)
					.listRowBackground(Color.clear)
				}

				Section {
					Picker("Sign in with", selection: Binding(get: { selected }, set: { provider = $0 })) {
						ForEach(accounts.providers) { Text($0.displayName).tag($0) }
					}
				} footer: {
					Text("Pick your GeForce NOW provider if it isn't NVIDIA, for example Cloud.GG in Australia.")
				}

				Section {
					Button {
						signIn()
					} label: {
						HStack {
							Spacer()
							if signingIn { ProgressView() } else { Text("Sign in").bold() }
							Spacer()
						}
					}
					.disabled(signingIn)
				} footer: {
					if let error {
						Text(error).foregroundStyle(.red)
					}
				}
			}
			.navigationTitle("iPlayGFN")
		}
		.task { await accounts.loadProviders() }
	}

	private func signIn() {
		signingIn = true
		error = nil
		let provider = selected
		Task {
			defer { signingIn = false }
			do {
				try await accounts.signIn(with: provider)
			} catch GFNError.signInCancelled {
			} catch {
				self.error = error.localizedDescription
			}
		}
	}
}
