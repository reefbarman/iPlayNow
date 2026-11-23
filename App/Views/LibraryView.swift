import SwiftUI

/// The games you own on GeForce NOW, as a grid of covers. Shows the last list
/// straight away, then refreshes it.
struct LibraryView: View {
	@Environment(GFNAccountStore.self) private var accounts
	@Environment(\.horizontalSizeClass) private var sizeClass
	@State private var games: [GFNGame] = GFNLibrary.cached()
	@State private var loading = false
	@State private var error: String?
	@State private var search = ""
	@State private var showingSettings = false
	@State private var choosingStore: GFNGame?
	@State private var editingGame: GFNGame?
	@State private var playing: Playing?
	@State private var selection: String?
	@State private var columnCount = 2
	@State private var gamepad = ListGamepadNavigator()
	@AppStorage("iplaynow.librarySort") private var sort = LibrarySort.recent
	/// A store name, or empty for every store
	@AppStorage("iplaynow.libraryStore") private var storeFilter = ""

	/// One launch: the game and which store's copy
	struct Playing: Identifiable {
		let game: GFNGame
		let variant: GFNGameVariant
		var id: String { variant.id }
	}

	private static let spacing: CGFloat = 16
	private static let margin: CGFloat = 16

	private var minimumCoverWidth: CGFloat { sizeClass == .regular ? 160 : 136 }

	/// Every store you own something on, for the filter
	private var stores: [String] {
		Set(games.flatMap { $0.ownedVariants.map(\.storeName) }).sorted()
	}

	private var shown: [GFNGame] {
		var list = games
		if !storeFilter.isEmpty {
			list = list.filter { $0.ownedVariants.contains { $0.storeName == storeFilter } }
		}
		let query = search.trimmingCharacters(in: .whitespaces)
		if !query.isEmpty {
			list = list.filter { $0.title.localizedCaseInsensitiveContains(query) }
		}
		switch sort {
		case .recent:
			// The service already returns most recently played first, then newest added
			break
		case .title:
			list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
		}
		return list
	}

	private var selectedGame: GFNGame? {
		shown.first { $0.id == selection }
	}

	/// What each button does for the selected cover
	private var gamepadHints: [GamepadHint] {
		guard let confirm = gamepad.confirmSymbol, let game = selectedGame else { return [] }
		var hints = [GamepadHint(symbol: confirm, label: "Play")]
		if let top = gamepad.topSymbol { hints.append(GamepadHint(symbol: top, label: "Video settings")) }
		if game.ownedVariants.count > 1, let left = gamepad.leftSymbol {
			hints.append(GamepadHint(symbol: left, label: "Choose store"))
		}
		return hints
	}

	private var gamepadActive: Bool {
		playing == nil && !showingSettings && choosingStore == nil && editingGame == nil
	}

	var body: some View {
		NavigationStack {
			GeometryReader { geo in
				ScrollViewReader { proxy in
					ScrollView {
						content
					}
					.onChange(of: selection) { _, id in
						guard let id, gamepad.confirmSymbol != nil else { return }
						withAnimation { proxy.scrollTo(id, anchor: .center) }
					}
				}
				.onAppear { updateColumns(width: geo.size.width) }
				.onChange(of: geo.size.width) { _, width in updateColumns(width: width) }
			}
			.safeAreaInset(edge: .bottom) {
				if !gamepadHints.isEmpty { GamepadHintBar(hints: gamepadHints) }
			}
			.searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
			.refreshable { await refresh() }
			.navigationTitle("iPlayNow")
			.toolbar {
				ToolbarItemGroup(placement: .topBarTrailing) {
					filterMenu
					sortMenu
					Button { showingSettings = true } label: {
						Image(systemName: "gearshape")
					}
					.accessibilityLabel("Settings")
				}
			}
			.sheet(isPresented: $showingSettings) { SettingsView() }
			.sheet(item: $editingGame) { GameSettingsView(game: $0) }
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
			gamepad.onMove = { moveSelection($0) }
			gamepad.onConfirm = {
				if let game = selectedGame { play(game) }
			}
			gamepad.onTop = {
				if let game = selectedGame { editingGame = game }
			}
			gamepad.onLeft = {
				if let game = selectedGame, game.ownedVariants.count > 1 { choosingStore = game }
			}
			gamepad.start()
			gamepad.setActive(gamepadActive)
			ensureSelection()
		}
		.onDisappear { gamepad.stop() }
		.onChange(of: gamepadActive) { _, active in gamepad.setActive(active) }
		.onChange(of: gamepad.confirmSymbol) { _, _ in ensureSelection() }
		.onChange(of: shown.map(\.id)) { _, _ in ensureSelection() }
		.onChange(of: stores) { _, stores in
			if !storeFilter.isEmpty, !stores.contains(storeFilter) { storeFilter = "" }
		}
	}

	@ViewBuilder
	private var content: some View {
		if games.isEmpty {
			Group {
				if loading {
					ProgressView("Loading your games…")
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
			.frame(maxWidth: .infinity)
			.padding(.top, 80)
		} else if shown.isEmpty {
			Group {
				if search.trimmingCharacters(in: .whitespaces).isEmpty {
					ContentUnavailableView {
						Label("Nothing on \(storeFilter)", systemImage: "line.3.horizontal.decrease.circle")
					} actions: {
						Button("Show all stores") { storeFilter = "" }
					}
				} else {
					ContentUnavailableView.search(text: search)
				}
			}
			.padding(.top, 80)
		} else {
			LazyVGrid(
				columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: columnCount),
				alignment: .leading,
				spacing: Self.spacing + 4
			) {
				ForEach(shown) { game in
					GameTile(
						game: game,
						selected: gamepad.confirmSymbol != nil && selection == game.id,
						play: { play(game) },
						chooseStore: game.ownedVariants.count > 1 ? { choosingStore = game } : nil,
						editSettings: { editingGame = game }
					)
					.id(game.id)
				}
			}
			.padding(.horizontal, Self.margin)
			.padding(.bottom, 24)
			if gamepad.confirmSymbol == nil {
				// With a controller, the hint bar covers this
				Text("Press and hold a cover for its video settings, or to choose a store when you own it on more than one.")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity)
					.multilineTextAlignment(.center)
					.padding(.horizontal, Self.margin)
					.padding(.bottom, 24)
			}
			if let error {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.padding(.horizontal, Self.margin)
					.padding(.bottom, 24)
			}
		}
	}

	private var filterMenu: some View {
		Menu {
			Picker("Store", selection: $storeFilter) {
				Text("All stores").tag("")
				ForEach(stores, id: \.self) { Text($0).tag($0) }
			}
		} label: {
			Image(systemName: storeFilter.isEmpty
				? "line.3.horizontal.decrease.circle"
				: "line.3.horizontal.decrease.circle.fill")
		}
		.accessibilityLabel("Filter")
	}

	private var sortMenu: some View {
		Menu {
			Picker("Sort", selection: $sort) {
				ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
			}
		} label: {
			Image(systemName: "arrow.up.arrow.down")
		}
		.accessibilityLabel("Sort")
	}

	private func updateColumns(width: CGFloat) {
		let available = width - Self.margin * 2
		guard available > 0 else { return }
		columnCount = max(2, Int((available + Self.spacing) / (minimumCoverWidth + Self.spacing)))
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

	/// Moves around the grid: left and right wrap between rows, up and down move a whole row
	private func moveSelection(_ move: ListGamepadNavigator.Move) {
		let ids = shown.map(\.id)
		guard !ids.isEmpty else { return }
		guard let current = selection, let index = ids.firstIndex(of: current) else {
			selection = ids.first
			return
		}
		let step = switch move {
		case .left: -1
		case .right: 1
		case .up: -columnCount
		case .down: columnCount
		}
		let next = index + step
		if ids.indices.contains(next) {
			selection = ids[next]
		} else if move == .down, index / columnCount < (ids.count - 1) / columnCount {
			// A short last row: drop to its last game
			selection = ids.last
		}
	}
}

enum LibrarySort: String, CaseIterable, Identifiable {
	case recent
	case title

	var id: Self { self }

	var label: String {
		switch self {
		case .recent: "Recently played"
		case .title: "A to Z"
		}
	}
}

/// A game's cover with its title under it. Tap to play.
private struct GameTile: View {
	let game: GFNGame
	let selected: Bool
	let play: () -> Void
	let chooseStore: (() -> Void)?
	let editSettings: () -> Void

	@Environment(GameSettingsStore.self) private var gameSettings

	var body: some View {
		Button(action: play) {
			VStack(alignment: .leading, spacing: 8) {
				cover
				VStack(alignment: .leading, spacing: 2) {
					Text(game.title)
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.primary)
						.lineLimit(2)
						.multilineTextAlignment(.leading)
					Text(storeLine)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(game.title)
		.accessibilityHint("Plays the game")
		.contextMenu {
			Button(action: play) { Label("Play", systemImage: "play.fill") }
			if let chooseStore {
				Button(action: chooseStore) { Label("Choose store", systemImage: "bag") }
			}
			Button(action: editSettings) { Label("Video settings", systemImage: "slider.horizontal.3") }
		}
	}

	/// The store it'll play on when there's a remembered choice, otherwise every store you own it on
	private var storeLine: String {
		if game.ownedVariants.count > 1, let remembered = StoreChoices.variant(for: game) {
			return "Plays on \(remembered.storeName)"
		}
		return game.ownedVariants.map(\.storeName).joined(separator: " · ")
	}

	private var cover: some View {
		Color.secondary.opacity(0.15)
			.aspectRatio(2.0 / 3.0, contentMode: .fit)
			.overlay {
				AsyncImage(url: game.boxArtURL) { phase in
					if let image = phase.image {
						image.resizable().aspectRatio(contentMode: .fill)
					} else {
						Image(systemName: "gamecontroller")
							.font(.largeTitle)
							.foregroundStyle(.secondary)
					}
				}
			}
			.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 0.5)
			}
			.overlay(alignment: .topTrailing) {
				// This game has its own video settings
				if let custom = gameSettings.settings(for: game.id) {
					Text(custom.hdr ? "\(custom.resolution.label) HDR" : custom.resolution.label)
						.font(.caption2.weight(.bold))
						.foregroundStyle(.white)
						.padding(.horizontal, 6)
						.padding(.vertical, 3)
						.background(.black.opacity(0.7), in: Capsule())
						.padding(6)
				}
			}
			.overlay(alignment: .bottomLeading) {
				// What GeForce NOW offers for this game, unlike the badge above which is your choice
				HStack(spacing: 4) {
					if game.supportsRTX { tag("RTX", fill: Color(red: 0.46, green: 0.73, blue: 0)) }
					if game.supportsHDR { tag("HDR", fill: .white, text: .black) }
				}
				.padding(6)
			}
			.scaleEffect(selected ? 1.04 : 1)
			.animation(.easeOut(duration: 0.15), value: selected)
	}

	private func tag(_ label: String, fill: Color, text: Color = .white) -> some View {
		Text(label)
			.font(.system(size: 9, weight: .heavy))
			.foregroundStyle(text)
			.padding(.horizontal, 4)
			.padding(.vertical, 2)
			.background(fill, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
			.shadow(color: .black.opacity(0.4), radius: 2)
			.accessibilityLabel(label == "RTX" ? "Ray tracing" : label)
	}
}

/// Which store's copy to launch, for games owned on more than one
private struct StoreChoiceView: View {
	let game: GFNGame
	let choose: (GFNGameVariant) -> Void
	@State private var remember = true
	@State private var gamepad = ListGamepadNavigator()
	/// The controller's row: a store, or the remember toggle after them
	@State private var row = 0
	@Environment(\.dismiss) private var dismiss

	private func highlight(_ index: Int) -> Color? {
		gamepad.confirmSymbol != nil && row == index ? Color.accentColor.opacity(0.18) : nil
	}

	private func pick(_ variant: GFNGameVariant) {
		if remember { StoreChoices.remember(variant, for: game) } else { StoreChoices.forget(game) }
		choose(variant)
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					ForEach(Array(game.ownedVariants.enumerated()), id: \.element.id) { index, variant in
						Button {
							pick(variant)
						} label: {
							HStack {
								Text(variant.storeName)
								Spacer()
								if StoreChoices.variant(for: game) == variant {
									Image(systemName: "checkmark").foregroundStyle(.tint)
								}
							}
						}
						.listRowBackground(highlight(index))
					}
				} footer: {
					Text("You own \(game.title) on more than one store. Your saves stay with the store you play on.")
				}
				Section {
					Toggle("Remember my choice", isOn: $remember)
						.listRowBackground(highlight(game.ownedVariants.count))
				} footer: {
					Text("Press and hold the game's cover to choose again, or press X on it with a controller.")
				}
			}
			.navigationTitle("Play on")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
			}
			.safeAreaInset(edge: .bottom) {
				if let confirm = gamepad.confirmSymbol, let cancel = gamepad.cancelSymbol {
					GamepadHintBar(hints: [
						GamepadHint(symbol: "dpad", label: "Move"),
						GamepadHint(symbol: confirm, label: "Select"),
						GamepadHint(symbol: cancel, label: "Cancel"),
					])
				}
			}
		}
		.presentationDetents([.medium, .large])
		.onAppear {
			let stores = game.ownedVariants
			gamepad.onMove = { move in
				switch move {
				case .up: row = max(0, row - 1)
				case .down: row = min(stores.count, row + 1)
				case .left, .right: if row == stores.count { remember.toggle() }
				}
			}
			gamepad.onConfirm = {
				if stores.indices.contains(row) { pick(stores[row]) } else { remember.toggle() }
			}
			gamepad.onCancel = { dismiss() }
			gamepad.start()
			gamepad.setActive(true)
		}
		.onDisappear { gamepad.stop() }
	}
}

/// The store picked for each game owned on several
enum StoreChoices {
	private static let key = "iplaynow.launchStore"

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
