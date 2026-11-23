import SwiftUI

/// The games you own on GeForce NOW. Shows the last list straight away, then refreshes it.
struct LibraryView: View {
	@Environment(GFNAccountStore.self) private var accounts
	@State private var games: [GFNGame] = GFNLibrary.cached()
	@State private var loading = false
	@State private var error: String?
	@State private var search = ""
	@State private var showingSettings = false
	@State private var choosingStore: GFNGame?
	@State private var playing: Playing?
	@State private var selection: String?
	@State private var gamepad = ListGamepadNavigator()

	/// One launch: the game and which store's copy
	struct Playing: Identifiable {
		let game: GFNGame
		let variant: GFNGameVariant
		var id: String { variant.id }
	}

	private var shown: [GFNGame] {
		let query = search.trimmingCharacters(in: .whitespaces)
		guard !query.isEmpty else { return games }
		return games.filter { $0.title.localizedCaseInsensitiveContains(query) }
	}

	private var gamepadActive: Bool {
		playing == nil && !showingSettings && choosingStore == nil
	}

	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
				List {
					if games.isEmpty {
						if loading {
							HStack {
								Spacer()
								ProgressView("Loading your games…")
								Spacer()
							}
							.listRowBackground(Color.clear)
						} else {
							ContentUnavailableView {
								Label("No games yet", systemImage: "gamecontroller")
							} description: {
								Text(error ?? "Games you own show up here once you've linked their stores (Steam, Epic, Xbox and others) in GeForce NOW.")
							} actions: {
								Button("Refresh") { Task { await refresh() } }.buttonStyle(.borderedProminent)
							}
						}
					}
					ForEach(shown) { game in
						let selected = gamepad.confirmSymbol != nil && selection == game.id
						GameRow(game: game, confirmSymbol: selected ? gamepad.confirmSymbol : nil) { play(game) }
							.id(game.id)
							.listRowBackground(selected ? Color.accentColor.opacity(0.18) : nil)
							.contextMenu {
								if game.ownedVariants.count > 1 {
									Button { choosingStore = game } label: {
										Label("Choose store", systemImage: "bag")
									}
								}
							}
					}
				}
				.onChange(of: selection) { _, id in
					guard let id else { return }
					withAnimation { proxy.scrollTo(id) }
				}
			}
			.searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
			.refreshable { await refresh() }
			.navigationTitle("iPlayGFN")
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button { showingSettings = true } label: { Image(systemName: "gearshape") }
				}
			}
			.sheet(isPresented: $showingSettings) { SettingsView() }
			.sheet(item: $choosingStore) { game in
				StoreChoiceView(game: game) { variant in
					choosingStore = nil
					playing = Playing(game: game, variant: variant)
				}
			}
			.fullScreenCover(item: $playing) { playing in
				StreamView(game: playing.game, variant: playing.variant)
			}
		}
		.task {
			guard !loading else { return }
			await refresh()
		}
		.onAppear {
			gamepad.onMove = { moveSelection(by: $0) }
			gamepad.onConfirm = {
				if let game = shown.first(where: { $0.id == selection }) { play(game) }
			}
			gamepad.start()
			gamepad.setActive(gamepadActive)
			ensureSelection()
		}
		.onDisappear { gamepad.stop() }
		.onChange(of: gamepadActive) { _, active in gamepad.setActive(active) }
		.onChange(of: gamepad.confirmSymbol) { _, _ in ensureSelection() }
		.onChange(of: games) { _, _ in ensureSelection() }
	}

	private func refresh() async {
		loading = true
		defer { loading = false }
		do {
			games = try await GFNLibrary.ownedGames(accounts: accounts)
			error = nil
		} catch {
			log.error("Library: \(error.localizedDescription, privacy: .public)")
			self.error = "Couldn't load your games. \(error.localizedDescription)"
		}
	}

	/// Straight in when there's one store, or a remembered choice; otherwise ask
	private func play(_ game: GFNGame) {
		let owned = game.ownedVariants
		if let remembered = StoreChoices.variant(for: game), owned.contains(remembered) {
			playing = Playing(game: game, variant: remembered)
		} else if owned.count > 1 {
			choosingStore = game
		} else if let only = owned.first ?? game.variants.first {
			playing = Playing(game: game, variant: only)
		}
	}

	private func ensureSelection() {
		if selection == nil || !shown.contains(where: { $0.id == selection }) {
			selection = shown.first?.id
		}
	}

	private func moveSelection(by delta: Int) {
		let ids = shown.map(\.id)
		guard !ids.isEmpty else { return }
		guard let current = selection, let index = ids.firstIndex(of: current) else {
			selection = ids.first
			return
		}
		selection = ids[min(max(index + delta, 0), ids.count - 1)]
	}
}

private struct GameRow: View {
	let game: GFNGame
	let confirmSymbol: String?
	let play: () -> Void

	var body: some View {
		HStack(spacing: 14) {
			AsyncImage(url: game.boxArtURL) { image in
				image.resizable().aspectRatio(contentMode: .fill)
			} placeholder: {
				Color.secondary.opacity(0.2)
					.overlay { Image(systemName: "gamecontroller").foregroundStyle(.secondary) }
			}
			.frame(width: 54, height: 72)
			.clipShape(RoundedRectangle(cornerRadius: 6))

			VStack(alignment: .leading, spacing: 3) {
				Text(game.title).font(.headline).lineLimit(2)
				Text(game.ownedVariants.map(\.storeName).joined(separator: " · "))
					.font(.caption).foregroundStyle(.secondary)
				if let remembered = StoreChoices.variant(for: game), game.ownedVariants.count > 1 {
					Label("Plays on \(remembered.storeName)", systemImage: "checkmark.circle")
						.font(.caption).foregroundStyle(.green)
				}
			}
			Spacer()
			Button(action: play) {
				if let confirmSymbol {
					HStack(spacing: 6) {
						Image(systemName: confirmSymbol)
						Text("Play")
					}
				} else {
					Text("Play")
				}
			}
			.buttonStyle(.borderedProminent)
		}
		.padding(.vertical, 4)
	}
}

/// Which store's copy to launch, for games owned on more than one
private struct StoreChoiceView: View {
	let game: GFNGame
	let choose: (GFNGameVariant) -> Void
	@State private var remember = true
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			Form {
				Section {
					ForEach(game.ownedVariants) { variant in
						Button {
							if remember { StoreChoices.remember(variant, for: game) } else { StoreChoices.forget(game) }
							choose(variant)
						} label: {
							HStack {
								Text(variant.storeName)
								Spacer()
								if StoreChoices.variant(for: game) == variant {
									Image(systemName: "checkmark").foregroundStyle(.tint)
								}
							}
						}
					}
				} footer: {
					Text("You own \(game.title) on more than one store. Your saves stay with the store you play on.")
				}
				Section {
					Toggle("Remember my choice", isOn: $remember)
				} footer: {
					Text("Press and hold the game in the list to choose again.")
				}
			}
			.navigationTitle("Play on")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
			}
		}
		.presentationDetents([.medium, .large])
	}
}

/// The store picked for each game owned on several
enum StoreChoices {
	private static let key = "iplaygfn.launchStore"

	private static var all: [String: String] {
		UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
	}

	static func variant(for game: GFNGame) -> GFNGameVariant? {
		guard let id = all[game.id] else { return nil }
		return game.ownedVariants.first { $0.id == id }
	}

	static func remember(_ variant: GFNGameVariant, for game: GFNGame) {
		var choices = all
		choices[game.id] = variant.id
		UserDefaults.standard.set(choices, forKey: key)
	}

	static func forget(_ game: GFNGame) {
		var choices = all
		choices[game.id] = nil
		UserDefaults.standard.set(choices, forKey: key)
	}
}
