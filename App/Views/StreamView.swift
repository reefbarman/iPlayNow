import GameController
import SwiftUI

struct StreamView: View {
	let console: Console
	/// Dial the console's remote address, chosen when the stream screen opened,
	/// so reconnects stay on the same route
	var remote = false

	@Environment(SettingsStore.self) private var settingsStore
	@Environment(ConsoleStore.self) private var consoleStore
	@Environment(BitrateMemory.self) private var bitrateMemory
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var scenePhase
	@State private var session: StreamSession?
	@State private var showMenu = false
	@State private var marketingScreenshotMode = false
	@State private var screenshotRequested = false
	@State private var isSavingScreenshot = false
	@State private var screenshotMessage: String?
	@State private var showScreenshotResult = false
	@State private var showMenuButton = false
	@State private var hideMenuButton: Task<Void, Never>?
	@State private var folded = false
	/// The user says this screen is fine, whatever the fold check thinks
	@State private var playHereAnyway = false
	/// Unfolded but the window is portrait: we wait (or pause) and ask the user
	/// to turn the phone. Once a stream is landscape, AppDelegate locks it there.
	@State private var portrait = false
	@State private var windowSize: CGSize = .zero
	@State private var hasController = ControllerInput.hasSupportedController
	@State private var autoShowsControls = !ControllerInput.hasSupportedController
	/// The connect prompt choice lasts across reconnects, not across play screens.
	@State private var sessionControlsMode: VirtualControlsMode?
	@State private var showSettingsHint = false
	@State private var showPSButton = false
	@State private var hidePSButton: Task<Void, Never>?
	@State private var showFGButton = false
	@State private var hideFGButton: Task<Void, Never>?
	@State private var pin = ""
	@State private var phone = PhoneStatus()
	@State private var showHeatWarning = false
	/// iOS 27 keeps the controller's Home button unless the user lets apps have it
	@State private var showHomeButtonPrompt = false
	/// The corner hints show once per stream screen, not again after a reconnect
	@State private var hintShown = false
	/// Auto bitrate's key for this console on the Wi-Fi network the stream started on
	@State private var bitrateKey: String?
	/// Lets the controller press the buttons on the connecting and error overlays
	@State private var gamepad = ListGamepadNavigator()

	private var needsController: Bool { !hasController && sessionControlsMode == nil }

	/// The controller drives the status overlays only while one is showing and uncovered.
	/// While streaming, its input goes to the console instead.
	private var overlayGamepadActive: Bool {
		guard let session, !folded, !portrait, !showMenu, scenePhase == .active else { return false }
		switch session.state {
		case .idle, .connecting, .needsPIN, .reconnecting, .applyingSettings, .ended: return true
		case .streaming, .consoleAsleep: return false
		}
	}

	private func overlayConfirm() {
		if case .ended = session?.state { session?.reconnect() }
	}

	private func overlayCancel() {
		switch session?.state {
		case .idle, .connecting, .needsPIN, .reconnecting, .applyingSettings, .ended: dismiss()
		default: break
		}
	}

	/// This console as currently stored, with any custom settings saved since the screen opened
	private var storedConsole: Console? { consoleStore.consoles.first { $0.id == console.id } }

	/// The shared settings with this console's own video and network settings on top
	private var baseSettings: StreamSettings {
		settingsStore.settings.applying(storedConsole?.customSettings)
	}

	/// The bitrate Auto bitrate has learned for this console on this network, if any
	private var learnedBitrate: Int? {
		guard baseSettings.autoBitrate, let bitrateKey else { return nil }
		return bitrateMemory.bitrate(for: bitrateKey)
	}

	/// What the stream uses: the base settings with any learned bitrate
	private var effectiveSettings: StreamSettings {
		var settings = baseSettings
		if let learnedBitrate { settings.bitrateMbps = learnedBitrate }
		return settings
	}

	/// Edits go to the console's own settings for video and network when it has them,
	/// and to the shared settings for everything else. With Auto bitrate, a bitrate
	/// change is remembered for this network instead of changing the starting bitrate.
	private var settingsBinding: Binding<StreamSettings> {
		Binding(
			get: { effectiveSettings },
			set: { new in
				var new = new
				if new.autoBitrate, baseSettings.autoBitrate, let bitrateKey, new.bitrateMbps != effectiveSettings.bitrateMbps {
					bitrateMemory.setManual(new.bitrateMbps, for: bitrateKey)
					new.bitrateMbps = baseSettings.bitrateMbps
				} else if learnedBitrate != nil, new.bitrateMbps == effectiveSettings.bitrateMbps {
					// Unchanged here, so keep the starting bitrate rather than saving the learned one over it
					new.bitrateMbps = baseSettings.bitrateMbps
				}
				guard var stored = storedConsole, stored.customSettings != nil else {
					settingsStore.settings = new
					return
				}
				if stored.customSettings != new.connection {
					stored.customSettings = new.connection
					consoleStore.update(stored)
				}
				var shared = new
				shared.connection = settingsStore.settings.connection
				if shared != settingsStore.settings { settingsStore.settings = shared }
			})
	}

	private var wantsVirtualControls: Bool {
		if marketingScreenshotMode { return true }
		return switch sessionControlsMode ?? settingsStore.settings.virtualControls {
		case .auto: !hasController && autoShowsControls
		case .always: true
		case .never: false
		}
	}

	private var canCaptureStream: Bool {
		guard let session else { return false }
		return session.state == .streaming && !session.goingToSleep && session.keyboardText == nil
			&& !folded && !portrait && scenePhase == .active
	}

	private var acceptsScreenInput: Bool { canCaptureStream && !showMenu }
	private var showsVirtualControls: Bool { acceptsScreenInput && wantsVirtualControls }
	private var pinsStreamButtons: Bool { marketingScreenshotMode && acceptsScreenInput }

	var body: some View {
		GeometryReader { geo in
			content
				.onAppear { updateFolded(geo.size) }
				.onChange(of: geo.size) { _, size in updateFolded(size) }
		}
		// The text input keyboard must not shrink our size: that reads as folded/portrait,
		// which hides the text box, which closes the keyboard, and round it goes
		.ignoresSafeArea(.keyboard)
		.statusBarHidden()
		.persistentSystemOverlays(.hidden)
		.defersSystemGestures(on: .all)
		// The session itself starts from updateFolded, once we know we're on a usable screen
		.onAppear {
			AppDelegate.setStreaming(true)
			refreshControllerPresence()
			gamepad.onConfirm = overlayConfirm
			gamepad.onCancel = overlayCancel
			gamepad.start()
			gamepad.setActive(overlayGamepadActive)
		}
		.onDisappear {
			gamepad.stop()
			stop()
		}
		.onChange(of: overlayGamepadActive) { _, active in gamepad.setActive(active) }
		.onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
			// A flip between the two landscapes keeps the same window size, so pick
			// up iOS's new orientation (for controller motion) once it has rotated
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { update() }
		}
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshControllerPresence() }
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshControllerPresence() }
		.task(id: hasController) {
			guard !hasController, !autoShowsControls else { return }
			try? await Task.sleep(for: .seconds(1))
			guard !Task.isCancelled, !hasController else { return }
			autoShowsControls = true
		}
		.onChange(of: settingsStore.settings.virtualControls) { _, _ in sessionControlsMode = nil }
		.onChange(of: session?.state == .streaming) { _, streaming in
			guard streaming, !hintShown else { return }
			hintShown = true
			flashSettingsHint()
			revealFGButton()
			askAboutHomeButtonOnce()
		}
		// Rest mode worked: straight back to the console list, no Reconnect screen
		.onChange(of: session?.state == .consoleAsleep) { _, asleep in
			if asleep { dismiss() }
		}
		.onChange(of: phone.isHot) { _, hot in
			if hot, effectiveSettings.fps > 30 { flashHeatWarning() }
		}
		// From the menu, the FG corner or an "Optimise connection" suggestion
		.onChange(of: effectiveSettings) { _, new in session?.apply(new) }
		.onChange(of: scenePhase) { _, phase in
			if phase == .active { refreshControllerPresence() }
			else { session?.setPaused(true) }
		}
		.sheet(isPresented: $showMenu, onDismiss: {
			guard screenshotRequested else { return }
			screenshotRequested = false
			isSavingScreenshot = true
		}) { menu }
		.task(id: isSavingScreenshot) {
			guard isSavingScreenshot else { return }
			await saveMarketingScreenshot()
		}
		.alert("Marketing Screenshot", isPresented: $showScreenshotResult) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(screenshotMessage ?? "")
		}
		.alert("Use Home as the PS button?", isPresented: $showHomeButtonPrompt) {
			Button("Open Settings") { HomeButtonSetting.openSettings() }
			Button("Not Now", role: .cancel) {}
		} message: {
			Text("iOS opens its Game Overlay when you press your controller's Home button. To open the PS5 menu instead, change the controller's Home button setting so apps can use it. You can find this again in Settings › Controller.")
		}
	}

	private static let homeButtonPromptKey = "homeButtonPromptShown"

	/// Once ever, the first time a stream starts with a controller while iOS 27
	/// keeps the Home button for itself
	private func askAboutHomeButtonOnce() {
		guard hasController, !marketingScreenshotMode,
			!UserDefaults.standard.bool(forKey: Self.homeButtonPromptKey),
			HomeButtonSetting.blocksApps
		else { return }
		UserDefaults.standard.set(true, forKey: Self.homeButtonPromptKey)
		showHomeButtonPrompt = true
	}

	private var content: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			if let session, let renderer = session.renderer {
				MetalStreamView(
					renderer: renderer,
					highRefresh: session.settings.highRefreshDisplay,
					acceptsInput: acceptsScreenInput,
					virtualControls: showsVirtualControls,
					controlsStyle: VirtualControlsStyle(effectiveSettings),
					videoAspectForLetterbox: letterboxAspect(for: session),
					onFrameGenerationTap: { activateFrameGenerationShortcut(session, pinned: pinsStreamButtons) },
					onVirtualPad: { [weak session] in session?.setVirtualPad($0) },
					onReset: { [weak session] in session?.resetScreenInput() },
					onTouch: { [weak session] in session?.screenTouch($0) },
					onTap: { [weak session] in session?.screenTap(slot: $0) },
					onCornerTap: revealMenuButton,
					onLeftCornerTap: revealPSButton
				)
				.ignoresSafeArea()
			}

			if let session {
				overlay(for: session)
			}

			if showSettingsHint && !showMenuButton && !marketingScreenshotMode {
				settingsHint
					.transition(.opacity)
			}

			if showMenuButton || pinsStreamButtons {
				menuButton
					.transition(.opacity)
			}

			if (showPSButton || pinsStreamButtons) && acceptsScreenInput {
				psButton
					.transition(.opacity)
			}

			if let session, acceptsScreenInput {
				frameGenButton(session, compact: showsVirtualControls, pinned: pinsStreamButtons)
				if session.settings.frameCapture {
					captureButton(session, compact: showsVirtualControls)
				}
				if session.micActive && !marketingScreenshotMode {
					micButton(session, raised: session.settings.frameCapture)
				}
			}

			if showHeatWarning {
				heatWarning
					.transition(.opacity)
			}

			if let notice = session?.notice {
				noticeBanner(notice)
					.transition(.opacity)
			}

			if let session, !marketingScreenshotMode, !folded, !portrait {
				if let check = session.connectionCheck {
					// With stats showing, the countdown sits in the stats line instead
					if session.settings.statsMode == .off {
						connectionCheckProgress(check, session: session)
							.transition(.opacity)
					}
				} else if let result = session.connectionCheckResult {
					connectionCheckResult(result, session: session)
						.transition(.opacity)
				}
			}

			if let session, let text = session.keyboardText, !folded, !portrait {
				KeyboardOverlay(
					initialText: text,
					onChange: { session.keyboardChanged($0) },
					onSubmit: { session.keyboardSubmit($0) },
					onCancel: { session.keyboardCancel() }
				)
			}

			if needsController && session == nil {
				controllerOverlay
			} else if folded {
				pausedOverlay
			} else if portrait {
				rotateOverlay
			}
		}
	}

	/// Used to map controller motion to the screen
	private var interfaceOrientation: UIInterfaceOrientation? {
		(UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation
	}

	// MARK: - Lifecycle

	private func refreshControllerPresence() {
		hasController = ControllerInput.hasSupportedController
		if hasController { autoShowsControls = false }
		update()
	}

	private func continueWithoutPhysicalController(_ mode: VirtualControlsMode) {
		sessionControlsMode = mode
		if mode == .auto { autoShowsControls = true }
		update()
	}

	private func startSession() {
		let key = LocalNetwork.currentKey().map { BitrateMemory.key(console: console.id, network: $0) }
		bitrateKey = key
		var settings = baseSettings
		if settings.autoBitrate, let key, let learned = bitrateMemory.bitrate(for: key) {
			settings.bitrateMbps = learned
			log.notice("Auto bitrate: using \(learned) Mbps learned for this network")
		}
		let remote = remote
		if remote { log.notice("Console isn't on the local network, using its remote address") }
		let session = StreamSession(console: (storedConsole ?? console).dialing(remote: remote), settings: settings)
		if let orientation = interfaceOrientation {
			session.input.interfaceOrientation = orientation
		}
		session.input.onMenuCombo = {
			if !isSavingScreenshot { showMenu = true }
		}
		let store = consoleStore, id = console.id
		session.latestConsole = { store.consoles.first { $0.id == id }?.dialing(remote: remote) }
		self.session = session
		session.start()
	}

	private func stop() {
		if let session {
			session.stop()
			// Learn from how it went, for the next time on this network
			if baseSettings.autoBitrate, let bitrateKey {
				for report in session.qualityReports {
					bitrateMemory.record(report, for: bitrateKey, starting: baseSettings.bitrateMbps)
				}
			}
		}
		session = nil
		AppDelegate.setStreaming(false)
	}

	/// On a foldable, streaming only happens on the inner screen: we wait for the
	/// unfold before connecting, and pause if it's folded mid-session.
	/// Normal iPhones are never "folded". iPhones play in landscape, while an
	/// iPad plays in any window shape (portrait, Split View, Stage Manager).
	private func updateFolded(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		AppDelegate.windowSizeChanged(size)
		windowSize = size
		update()
	}

	private func update() {
		let size = windowSize
		guard size.width > 0, size.height > 0 else { return }
		let isFolded = DeviceLayout.isFolded(size) && !playHereAnyway
		folded = isFolded
		portrait = !isFolded && !DeviceLayout.isPad && size.height > size.width
		let canPlay = !isFolded && !portrait
		guard session != nil else {
			if canPlay && !needsController && scenePhase == .active { startSession() }
			return
		}
		session?.setPaused(!canPlay || scenePhase != .active)
		if let orientation = interfaceOrientation {
			session?.input.interfaceOrientation = orientation
		}
	}

	// MARK: - Menu button (top-right hot corner)

	private func revealMenuButton() {
		withAnimation(.easeOut(duration: 0.2)) { showMenuButton = true }
		hideMenuButton?.cancel()
		hideMenuButton = Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.6)) { showMenuButton = false }
		}
	}

	// MARK: - PS button (top-left hot corner)

	private func revealPSButton() {
		withAnimation(.easeOut(duration: 0.2)) { showPSButton = true }
		schedulePSButtonHide()
	}

	private func schedulePSButtonHide() {
		hidePSButton?.cancel()
		hidePSButton = Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.6)) { showPSButton = false }
		}
	}

	private var psButton: some View {
		Button {
			session?.pressPSButton()
			// Stay visible a little longer in case they want to press it again
			schedulePSButtonHide()
		} label: {
			Image(systemName: "playstation.logo")
				.font(.title2)
				.foregroundStyle(.white)
				.frame(width: 52, height: 52)
				.background(.black.opacity(0.55), in: Circle())
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.padding(.top, 14)
		.padding(.leading, 20)
		.ignoresSafeArea()
	}

	/// Each time a stream starts, point at the hidden corners, then fade out
	private func flashSettingsHint() {
		withAnimation(.easeOut(duration: 0.3)) { showSettingsHint = true }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(4))
			withAnimation(.easeIn(duration: 0.8)) { showSettingsHint = false }
		}
	}

	private var settingsHint: some View {
		// Smaller iPhones don't have room for the full wording on both sides
		ViewThatFits(in: .horizontal) {
			settingsHintRow(ps: "Tap this corner for the PS button", settings: "Tap this corner for settings")
			settingsHintRow(ps: "PS button", settings: "Settings")
		}
		.foregroundStyle(.white)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.padding(.top, 14)
		.padding(.horizontal, 20)
		.ignoresSafeArea()
		.allowsHitTesting(false)
	}

	private func settingsHintRow(ps: String, settings: String) -> some View {
		HStack(alignment: .top) {
			if !showPSButton {
				HStack(spacing: 10) {
					hintIcon("playstation.logo")
					Image(systemName: "arrow.left")
						.font(.title3.weight(.bold))
					hintLabel(ps)
				}
			}
			Spacer(minLength: 16)
			HStack(spacing: 10) {
				hintLabel(settings)
				Image(systemName: "arrow.right")
					.font(.title3.weight(.bold))
				hintIcon("gearshape.fill")
			}
		}
	}

	// MARK: - Frame generation toggle (bottom right)

	/// Shows the frame generation label, then fades it out like the other corners
	private func revealFGButton() {
		withAnimation(.easeOut(duration: 0.2)) { showFGButton = true }
		hideFGButton?.cancel()
		hideFGButton = Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.6)) { showFGButton = false }
		}
	}

	private func activateFrameGenerationShortcut(_ session: StreamSession, pinned: Bool = false) {
		// The stream picks the change up from onChange(of: effectiveSettings)
		if pinned || showFGButton {
			settingsStore.settings.frameGeneration.toggle()
		}
		revealFGButton()
	}

	private func letterboxAspect(for session: StreamSession) -> CGFloat? {
		guard session.settings.displayMode == .fit else { return nil }
		let stats = session.stats
		if stats.width > 0, stats.height > 0 { return CGFloat(stats.width) / CGFloat(stats.height) }
		return 16.0 / 9.0
	}

	/// The UIKit touch router handles the rest of the original hotspot in virtual mode,
	/// so a fixed gameplay button can claim a touch first.
	private func frameGenButton(_ session: StreamSession, compact: Bool, pinned: Bool = false) -> some View {
		let on = settingsStore.settings.frameGeneration
		let visible = pinned || showFGButton
		let (text, colour): (String, Color) = on ? ("FG on", .green.opacity(0.85)) : ("FG off", .black.opacity(0.45))
		let badge = Text(text)
			.font(.caption.weight(.bold))
			.foregroundStyle(.white)
			.padding(.horizontal, 10)
			.frame(minWidth: 52, minHeight: 30)
			.background(colour, in: Capsule())
			.fixedSize()
		return ZStack(alignment: .bottomTrailing) {
			Button {
				activateFrameGenerationShortcut(session, pinned: pinned)
			} label: {
				badge.opacity(visible ? 1 : 0)
					.padding(.bottom, 12)
					.padding(.trailing, 16)
					.frame(width: compact ? 84 : StreamMetalView.frameGenerationCornerSize.width,
						height: compact ? 54 : StreamMetalView.frameGenerationCornerSize.height, alignment: .bottomTrailing)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Frame generation \(on ? "on" : "off"). Tap to turn it \(on ? "off" : "on").")

			if showSettingsHint && showFGButton && !pinned {
				// Lay out the hint beside a placeholder the same size as the actual badge.
				HStack(spacing: 10) {
					hintLabel("Tap here for frame generation")
					Image(systemName: "arrow.right")
						.font(.title3.weight(.bold))
						.accessibilityHidden(true)
					badge.hidden()
				}
				.foregroundStyle(.white)
				.padding(.horizontal, 16)
				.padding(.bottom, 12)
				.allowsHitTesting(false)
				.transition(.opacity)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.ignoresSafeArea()
	}

	// MARK: - Frame capture (debug, bottom left)

	/// Saves the last few seconds of frames, real and generated, for a closer look
	private func captureButton(_ session: StreamSession, compact: Bool) -> some View {
		Button {
			session.saveFrameCapture()
		} label: {
			HStack(spacing: 8) {
				Image(systemName: "record.circle")
					.font(.title3)
					.foregroundStyle(.red)
				if let status = session.captureStatus {
					Text(status)
						.font(.caption.weight(.semibold))
						.foregroundStyle(.white)
						.lineLimit(compact ? 1 : 2)
						.frame(maxWidth: compact ? 70 : nil, alignment: .leading)
				}
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(.black.opacity(0.45), in: Capsule())
			.opacity(session.captureStatus == nil ? 0.6 : 1)
			.padding(.bottom, 12)
			.padding(.leading, 16)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Save the last few seconds of frames")
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		.ignoresSafeArea()
	}

	// MARK: - Microphone (bottom left)

	/// Mutes and unmutes the mic. Sits above the frame capture button when that's on.
	private func micButton(_ session: StreamSession, raised: Bool) -> some View {
		Button {
			session.toggleMicMuted()
		} label: {
			Image(systemName: session.micMuted ? "mic.slash.fill" : "mic.fill")
				.font(.title3)
				.foregroundStyle(session.micMuted ? .red : .white)
				.frame(width: 24, height: 24)
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.background(.black.opacity(0.45), in: Capsule())
				.opacity(session.micMuted ? 1 : 0.6)
				.padding(.bottom, raised ? 56 : 12)
				.padding(.leading, 16)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(session.micMuted ? "Unmute microphone" : "Mute microphone")
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		.ignoresSafeArea()
	}

	// MARK: - Heat warning

	private func flashHeatWarning() {
		withAnimation(.easeOut(duration: 0.3)) { showHeatWarning = true }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(8))
			withAnimation(.easeIn(duration: 0.8)) { showHeatWarning = false }
		}
	}

	private var heatWarning: some View {
		HStack(spacing: 8) {
			Image(systemName: "thermometer.high")
			Text("Your \(DeviceLayout.deviceNoun) is getting hot. Switching to 30 fps in settings will help it cool down.")
		}
		.font(.subheadline.weight(.semibold))
		.foregroundStyle(.white)
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
		.background(.black.opacity(0.7), in: Capsule())
		.padding(.horizontal, 20)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
		.padding(.bottom, 16)
		.allowsHitTesting(false)
	}

	private func noticeBanner(_ text: String) -> some View {
		HStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
			Text(text)
		}
		.font(.subheadline.weight(.semibold))
		.foregroundStyle(.white)
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
		.background(.black.opacity(0.7), in: Capsule())
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.padding(.top, 16)
		.allowsHitTesting(false)
	}

	// MARK: - Optimise connection

	private func connectionCheckProgress(_ check: ConnectionCheck, session: StreamSession) -> some View {
		HStack(spacing: 10) {
			ProgressView(value: check.progress)
				.progressViewStyle(.circular)
				.tint(.white)
			VStack(alignment: .leading, spacing: 2) {
				Text("Checking the connection… \(check.secondsLeft) s").font(.subheadline.weight(.semibold))
				Text("Keep playing, ideally something busy").font(.caption).foregroundStyle(.white.opacity(0.7))
			}
			Button("Cancel") { session.dismissConnectionCheck() }
				.font(.subheadline.weight(.semibold))
				.buttonStyle(.bordered)
				.tint(.white)
		}
		.foregroundStyle(.white)
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
		.background(.black.opacity(0.7), in: Capsule())
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.padding(.top, 16)
	}

	private func connectionCheckResult(_ result: ConnectionCheckResult, session: StreamSession) -> some View {
		let (symbol, colour): (String, Color) = switch result.verdict {
		case .good, .roomToGrow: ("checkmark.circle.fill", .green)
		case .minorHiccups: ("exclamationmark.circle.fill", .yellow)
		case .tooHigh: ("exclamationmark.triangle.fill", .orange)
		case .inconclusive: ("questionmark.circle.fill", .secondary)
		}
		return VStack(alignment: .leading, spacing: 10) {
			Label {
				Text(result.title).font(.headline)
			} icon: {
				Image(systemName: symbol).foregroundStyle(colour)
			}
			Text(result.detail)
				.font(.subheadline)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				if result.hasSuggestion {
					Button(result.applyLabel) {
						var settings = effectiveSettings
						result.apply(to: &settings)
						session.dismissConnectionCheck()
						settingsBinding.wrappedValue = settings
					}
					.buttonStyle(.borderedProminent)
					Button("Keep current") { session.dismissConnectionCheck() }
						.buttonStyle(.bordered)
				} else {
					Button("OK") { session.dismissConnectionCheck() }
						.buttonStyle(.borderedProminent)
				}
				Spacer()
				Button("Check again") { session.startConnectionCheck() }
					.buttonStyle(.bordered)
			}
			if result.bitrateMbps != nil || result.networkSmoothing != nil {
				Text("Applying reconnects the stream.").font(.caption).foregroundStyle(.secondary)
			}
		}
		.padding(16)
		.frame(maxWidth: 460)
		.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		// Centred, clear of the stats along the top
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
	}

	private func hintLabel(_ text: String) -> some View {
		Text(text)
			.font(.subheadline.weight(.semibold))
			.padding(.horizontal, 14)
			.padding(.vertical, 8)
			.background(.black.opacity(0.65), in: Capsule())
	}

	private func hintIcon(_ systemName: String) -> some View {
		Image(systemName: systemName)
			.font(.title2)
			.frame(width: 52, height: 52)
			.background(.black.opacity(0.55), in: Circle())
	}

	private var menuButton: some View {
		Button {
			guard !isSavingScreenshot else { return }
			hideMenuButton?.cancel()
			showMenuButton = false
			showMenu = true
		} label: {
			Image(systemName: "gearshape.fill")
				.font(.title2)
				.foregroundStyle(.white)
				.frame(width: 52, height: 52)
				.background(.black.opacity(0.55), in: Circle())
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
		.padding(.top, 14)
		.padding(.trailing, 20)
		.ignoresSafeArea()
	}

	// MARK: - Overlays

	@ViewBuilder
	private func overlay(for session: StreamSession) -> some View {
		switch session.state {
		case .idle, .connecting:
			VStack(spacing: 12) {
				ProgressView().controlSize(.large)
				Text("Connecting to \(console.name)…").foregroundStyle(.secondary)
				Button { dismiss() } label: { gamepadLabel("Cancel", gamepad.cancelSymbol) }.buttonStyle(.bordered)
			}
		case .streaming where session.goingToSleep, .consoleAsleep:
			VStack(spacing: 12) {
				ProgressView().controlSize(.large)
				Text("Putting \(console.name) in rest mode…").font(.headline)
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		case .streaming:
			// Held back while the corner hints are up so the two don't overlap
			if session.settings.statsMode != .off && !marketingScreenshotMode
				&& !(showSettingsHint && !showMenuButton) {
				StatsOverlay(stats: session.stats, settings: session.settings, videoAspect: letterboxAspect(for: session),
					checkSecondsLeft: session.connectionCheck?.secondsLeft)
					.allowsHitTesting(false)
					.transition(.opacity)
			}
		case .needsPIN(let incorrect):
			VStack(spacing: 12) {
				Text(incorrect ? "Incorrect PIN, try again" : "Enter your Remote Play PIN").font(.headline)
				SecureField("PIN", text: $pin)
					.keyboardType(.numberPad)
					.textFieldStyle(.roundedBorder)
					.frame(width: 200)
				HStack {
					Button { dismiss() } label: { gamepadLabel("Cancel", gamepad.cancelSymbol) }.buttonStyle(.bordered)
					Button("OK") {
						session.submitPIN(pin)
						pin = ""
					}
					.buttonStyle(.borderedProminent)
				}
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		case .reconnecting(let attempt):
			VStack(spacing: 12) {
				ProgressView().controlSize(.large)
				Text("Connection lost. Reconnecting…").font(.headline)
				Text("Attempt \(attempt) of \(StreamSession.maxReconnectAttempts)").foregroundStyle(.secondary)
				Button { dismiss() } label: { gamepadLabel("Cancel", gamepad.cancelSymbol) }.buttonStyle(.bordered)
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		case .applyingSettings(let attempt):
			VStack(spacing: 12) {
				ProgressView().controlSize(.large)
				Text("Reconnecting with new settings…").font(.headline)
				if attempt > 1 {
					Text("\(console.name) isn't ready yet. Attempt \(attempt)").foregroundStyle(.secondary)
				}
				Button { dismiss() } label: { gamepadLabel("Cancel", gamepad.cancelSymbol) }.buttonStyle(.bordered)
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		case .ended(let error):
			VStack(spacing: 12) {
				if let error {
					Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
					Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
				} else {
					Text("Disconnected")
				}
				HStack {
					Button { dismiss() } label: { gamepadLabel("Close", gamepad.cancelSymbol) }.buttonStyle(.bordered)
					Button { session.reconnect() } label: { gamepadLabel("Reconnect", gamepad.confirmSymbol) }
						.buttonStyle(.borderedProminent)
				}
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		}
	}

	/// A button title with the controller button that presses it, when a controller is connected
	@ViewBuilder
	private func gamepadLabel(_ title: String, _ symbol: String?) -> some View {
		if let symbol {
			HStack(spacing: 6) {
				Image(systemName: symbol)
				Text(title)
			}
		} else {
			Text(title)
		}
	}

	private var controllerOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "gamecontroller.fill").font(.largeTitle)
				Text("No controller connected").font(.title2.bold())
				Text("Turn on your controller or pair it in Settings › Bluetooth, and \(console.name) connects as soon as it's found. You can also play with virtual controls or connect without controls.")
					.multilineTextAlignment(.center)
					.foregroundStyle(.secondary)
					.frame(maxWidth: 420)
				ViewThatFits {
					HStack { controllerChoices }
					VStack { controllerChoices }
				}
				.padding(.top, 8)
			}
			.padding(24)
		}
	}

	@ViewBuilder
	private var controllerChoices: some View {
		Button("Use virtual controls") { continueWithoutPhysicalController(.auto) }.buttonStyle(.borderedProminent)
		Button("Connect without controls") { continueWithoutPhysicalController(.never) }.buttonStyle(.bordered)
		Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(.bordered)
	}

	private var rotateOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "rotate.right").font(.largeTitle)
				Text("Turn your phone sideways").font(.title2.bold())
				Text(session == nil ? "\(console.name) connects once you're in landscape." : "Turn to landscape to keep playing.")
					.foregroundStyle(.secondary)
				Button(session == nil ? "Cancel" : "Disconnect") { dismiss() }.buttonStyle(.bordered).padding(.top, 8)
			}
		}
	}

	private var pausedOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "rectangle.portrait.and.arrow.forward").font(.largeTitle)
				if session == nil {
					Text("Open your phone to play").font(.title2.bold())
					Text("\(console.name) connects as soon as you unfold.").foregroundStyle(.secondary)
					HStack {
						Button("Cancel") { dismiss() }.buttonStyle(.bordered)
						Button("Play here anyway") {
							log.notice("Play here anyway at \(Int(windowSize.width), privacy: .public)x\(Int(windowSize.height), privacy: .public)pt")
							playHereAnyway = true
							update()
						}
						.buttonStyle(.bordered)
					}
					.padding(.top, 8)
				} else {
					Text("Paused").font(.title2.bold())
					Text("Unfold to keep playing.").foregroundStyle(.secondary)
					Button("Disconnect") { dismiss() }.buttonStyle(.bordered).padding(.top, 8)
				}
			}
		}
	}

	private var menu: some View {
		let settings = settingsBinding
		let customName = storedConsole?.customSettings != nil ? console.name : nil
		return NavigationStack {
			Form {
				Section {
					Button("Resume") { showMenu = false }
					if wantsVirtualControls, let status = session?.captureStatus {
						Text(status).foregroundStyle(.secondary)
					}
					if let session, session.micActive {
						Button(session.micMuted ? "Unmute microphone" : "Mute microphone") {
							session.toggleMicMuted()
						}
					}
					Button("Put console in rest mode") {
						session?.putConsoleToSleep()
						showMenu = false
					}
					Button("Disconnect", role: .destructive) {
						showMenu = false
						dismiss()
					}
				}
				Section {
					LabeledContent {
						Text(phone.batteryText)
					} label: {
						Label("Battery", systemImage: phone.batterySymbol)
					}
					LabeledContent {
						Text(phone.thermalText).foregroundStyle(phone.isHot ? .orange : .secondary)
					} label: {
						Label("Temperature", systemImage: "thermometer.medium")
					}
					if phone.isHot && settings.wrappedValue.fps > 30 {
						Button("Switch to 30 fps to cool down") { settings.wrappedValue.fps = 30 }
					}
				} header: {
					Text(DeviceLayout.isPad ? "iPad" : "Phone")
				}
				Section {
					if session?.connectionCheck != nil {
						Button("Stop the connection check", role: .destructive) {
							session?.dismissConnectionCheck()
						}
					} else {
						Button {
							session?.startConnectionCheck()
							showMenu = false
						} label: {
							Label("Optimise connection", systemImage: "wifi")
						}
						.disabled(session?.state != .streaming)
					}
				} header: {
					Text("Connection")
				} footer: {
					Text("Watches the next \(ConnectionCheck.duration) seconds of the stream for lost video, then suggests a bitrate (and network smoothing) you can apply with one tap. Play something with plenty of movement while it checks, since the PS5 sends much less on menus and quiet scenes.")
				}

				if let sessionControlsMode, sessionControlsMode != settingsStore.settings.virtualControls {
					Section {
						LabeledContent("Virtual controls this session", value: sessionControlsMode.label)
						Button("Use saved virtual controls setting") { self.sessionControlsMode = nil }
					}
				}
				StreamSettingsForm(settings: settings, customConsoleName: customName,
					bitrateTitle: baseSettings.autoBitrate && bitrateKey != nil ? "Bitrate on this network" : nil,
					showsControllerTest: true, onControllerTest: { [session] in session?.lendController($0) })
				Section {
					Toggle("Marketing screenshot mode", isOn: $marketingScreenshotMode)
					Button {
						marketingScreenshotMode = true
						screenshotRequested = true
						showMenu = false
					} label: {
						Label("Save screenshot", systemImage: "camera")
					}
					.disabled(!canCaptureStream || isSavingScreenshot)
				} footer: {
					Text("Screenshot mode keeps virtual controls and shortcuts visible while you frame the shot. Save screenshot saves a PNG to \(DeviceLayout.filesLocation), then returns the controls to normal.")
				}
			}
			.navigationTitle(console.name)
			.navigationBarTitleDisplayMode(.inline)
		}
	}

	private func saveMarketingScreenshot() async {
		defer {
			marketingScreenshotMode = false
			isSavingScreenshot = false
		}
		do {
			guard canCaptureStream, !showMenu, let renderer = session?.renderer else {
				throw MarketingScreenshot.CaptureError.streamUnavailable
			}
			let filename = try await MarketingScreenshot.save(renderer: renderer)
			guard !Task.isCancelled else { return }
			screenshotMessage = "Saved \(filename) to \(DeviceLayout.filesLocation)."
		} catch {
			guard !Task.isCancelled else { return }
			screenshotMessage = "Couldn't save the screenshot. \(error.localizedDescription)"
		}
		showScreenshotResult = true
	}
}

/// Stats, centred along the top. With a letterboxed picture they sit in the black bar
/// above it and spread across it; otherwise they float over the top of the picture.
private struct StatsOverlay: View {
	let stats: StreamStats
	let settings: StreamSettings
	/// The picture's aspect ratio when it's fitted (letterboxed), nil when it fills the screen
	let videoAspect: CGFloat?
	/// Optimise connection is running: seconds until it's done
	var checkSecondsLeft: Int?

	/// Keeps clear of the PS button and settings hot corners
	private static let cornerReserve: CGFloat = 84
	/// Below this there's no usable bar, so float over the picture instead
	private static let minBarHeight: CGFloat = 28

	private struct Item: Identifiable {
		let label: String
		let value: String
		var warn = false
		var id: String { label }
	}

	var body: some View {
		GeometryReader { geo in
			let bar = barHeight(in: geo.size)
			let inBar = bar >= Self.minBarHeight
			content(roomy: inBar && bar >= 44)
				.padding(.horizontal, inBar ? 0 : 10)
				.padding(.vertical, inBar ? 4 : 6)
				.background(.black.opacity(inBar ? 0 : 0.55), in: RoundedRectangle(cornerRadius: 8))
				.frame(maxWidth: max(0, geo.size.width - Self.cornerReserve * 2))
				.frame(minHeight: inBar ? bar : nil)
				.padding(.top, inBar ? 0 : 12)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		}
		.ignoresSafeArea()
		.foregroundStyle(.white)
	}

	/// The black bar above the picture, in points (0 when there isn't one)
	private func barHeight(in size: CGSize) -> CGFloat {
		guard let videoAspect, size.width > 0 else { return 0 }
		return max(0, (size.height - size.width / videoAspect) / 2)
	}

	@ViewBuilder
	private func content(roomy: Bool) -> some View {
		switch settings.statsMode {
		case .off:
			EmptyView()
		case .simple:
			HStack(spacing: roomy ? 20 : 14) {
				ForEach(simpleItems) { cell($0, valueFirst: true) }
			}
			.font((roomy ? Font.footnote : .caption2).monospaced())
		case .advanced:
			StatsFlow(spacing: 10, lineSpacing: 2) {
				ForEach(advancedItems) { cell($0) }
			}
			.font(.caption2.monospaced())
		}
	}

	private func cell(_ item: Item, valueFirst: Bool = false) -> some View {
		let label = Text(item.label).foregroundStyle(.white.opacity(0.55))
		let value = Text(item.value).foregroundStyle(item.warn ? .orange : .white)
		return HStack(spacing: 4) {
			if valueFirst {
				value
				if !item.label.isEmpty { label }
			} else {
				label
				value
			}
		}
		.lineLimit(1)
		.minimumScaleFactor(0.7)
	}

	private var lossPercent: Double { stats.packetLoss * 100 }
	private var codec: String { "\(settings.effectiveCodec == .h265 ? "HEVC" : "H.264")\(settings.hdr ? " HDR" : "")" }

	private var simpleItems: [Item] {
		var items = [
			Item(label: "", value: stats.height > 0 ? "\(stats.height)p" : "–"),
			Item(label: "fps", value: "\(Int(stats.fps))"),
			Item(label: "Mbps", value: String(format: "%.1f", stats.bitrateMbps)),
			Item(label: "ping", value: String(format: "%.0f ms", stats.rttMs), warn: stats.rttMs > 40),
			Item(label: "loss", value: String(format: "%.1f%%", lossPercent), warn: lossPercent >= 1),
		]
		if settings.frameGeneration {
			items.append(Item(label: "FG", value: stats.frameGenActive ? "+\(stats.generatedFPS)" : "off", warn: !stats.frameGenActive))
		}
		appendCheck(&items)
		return items
	}

	private func appendCheck(_ items: inout [Item]) {
		guard let checkSecondsLeft else { return }
		items.append(Item(label: "checking", value: "\(checkSecondsLeft)s", warn: true))
	}

	/// Related values share a cell with short labels so the advanced stats stay
	/// compact along the top.
	private var advancedItems: [Item] {
		let hz = stats.displayHz > 0 ? " @\(Int(stats.displayHz))Hz" : ""
		var items = [
			Item(label: "", value: "\(stats.width)×\(stats.height) \(codec)"),
			Item(label: "fps", value: "\(Int(stats.fps))\(hz)"),
			Item(label: "Mbps", value: String(format: "%.1f/%d", stats.bitrateMbps, settings.bitrateMbps)),
			Item(label: "ping", value: String(format: "%.0fms", stats.rttMs), warn: stats.rttMs > 40),
			Item(label: "loss", value: String(format: "%.1f%%", lossPercent), warn: lossPercent >= 1),
			Item(label: "dec", value: String(format: "%.1fms", stats.decodeMs)),
		]
		addCounter(&items, "lost/fail", stats.lostFrames, stats.failedFrames, warnIfNonZero: true)
		if settings.takionV20, stats.takionVersion > 0 {
			let declined = stats.takionVersion < 20
			items.append(Item(label: "takion", value: "v\(stats.takionVersion)\(declined ? " v20 declined" : "")", warn: declined))
		}
		if settings.frameGeneration {
			if stats.frameGenActive {
				var fg = String(format: "+%d %.1fms", stats.generatedFPS, stats.generateMs)
				if let status = stats.frameGenStatus, !status.isEmpty { fg += " \(status)" }
				items.append(Item(label: "FG", value: fg))
				addCounter(&items, "skip/rep", stats.skippedFrames, stats.repeatedFrames)
			} else {
				items.append(Item(label: "FG", value: "off (screen too slow)", warn: true))
			}
		}
		if let s = stats.smoothing {
			items.append(Item(label: "wait", value: String(format: "%.0fms", s.waitMs)))
			addCounter(&items, "late/skip", s.packetsLate, s.packetsSkipped)
			addCounter(&items, "fec", s.fecFailures)
			addCounter(&items, "patched", s.framesPatched)
			addCounter(&items, "held/drop", s.heldFrames, s.droppedFrames)
			addCounter(&items, "dry", s.underruns)
		}
		if let controller = stats.controller {
			let short = controller
				.replacingOccurrences(of: " Wireless Controller", with: "")
				.replacingOccurrences(of: " Controller", with: "")
			items.append(Item(label: "pad", value: short))
		}
		appendCheck(&items)
		return items
	}

	/// Adds a counter cell, one value or a pair shown as a/b
	private func addCounter(_ items: inout [Item], _ label: String, _ values: Int..., warnIfNonZero: Bool = false) {
		let counted = values.contains { $0 != 0 }
		items.append(Item(label: label, value: values.map(String.init).joined(separator: "/"), warn: warnIfNonZero && counted))
	}
}

/// Lays cells out left to right in centred rows, each cell only taking the
/// width it needs. Uses as few rows as fit, then narrows them until they're
/// about even, rather than one full row and a short leftover.
private struct StatsFlow: Layout {
	var spacing: CGFloat
	var lineSpacing: CGFloat

	private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
		let maxWidth = width.isFinite ? width : .greatestFiniteMagnitude
		let count = greedyRows(subviews, width: maxWidth).count
		guard count > 1 else { return greedyRows(subviews, width: maxWidth) }
		// The narrowest width that still needs no more rows
		var low = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
		var high = min(maxWidth, rowWidth(greedyRows(subviews, width: .greatestFiniteMagnitude)[0]))
		while high - low > 1 {
			let mid = (low + high) / 2
			if greedyRows(subviews, width: mid).count <= count { high = mid } else { low = mid }
		}
		return greedyRows(subviews, width: high)
	}

	private func greedyRows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
		var rows: [[(index: Int, size: CGSize)]] = [[]]
		var x: CGFloat = 0
		for (index, view) in subviews.enumerated() {
			let size = view.sizeThatFits(.unspecified)
			if x > 0, x + spacing + size.width > width {
				rows.append([])
				x = 0
			}
			x += (x > 0 ? spacing : 0) + size.width
			rows[rows.count - 1].append((index, size))
		}
		return rows
	}

	private func rowWidth(_ row: [(index: Int, size: CGSize)]) -> CGFloat {
		row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1))
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let rows = rows(subviews, width: proposal.width ?? .infinity)
		let width = rows.map(rowWidth).max() ?? 0
		let height = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) }
			+ lineSpacing * CGFloat(max(0, rows.count - 1))
		return CGSize(width: width, height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var y = bounds.minY
		for row in rows(subviews, width: bounds.width) {
			var x = bounds.minX + (bounds.width - rowWidth(row)) / 2
			let height = row.map(\.size.height).max() ?? 0
			for cell in row {
				subviews[cell.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(cell.size))
				x += cell.size.width + spacing
			}
			y += height + lineSpacing
		}
	}
}

/// Shown when a text box opens on the PS5: type with the iOS keyboard instead of
/// the controller. Every change is sent, Send submits and Cancel closes the box.
private struct KeyboardOverlay: View {
	let initialText: String
	let onChange: (String) -> Void
	let onSubmit: (String) -> Void
	let onCancel: () -> Void

	@State private var text = ""
	@FocusState private var focused: Bool

	var body: some View {
		VStack(spacing: 12) {
			Text("Type on your \(DeviceLayout.deviceNoun)").font(.headline)
			TextField("Text", text: $text)
				.textFieldStyle(.roundedBorder)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.submitLabel(.send)
				.focused($focused)
				.onSubmit { onSubmit(text) }
				.frame(maxWidth: 520)
			HStack {
				Button("Cancel", action: onCancel).buttonStyle(.bordered)
				Button("Send") { onSubmit(text) }.buttonStyle(.borderedProminent)
			}
		}
		.padding(20)
		.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.padding(.top, 16)
		.onAppear {
			text = initialText
			focused = true
		}
		.onChange(of: text) { _, new in onChange(new) }
	}
}

/// Hosts the CAMetalLayer-backed view in SwiftUI.
private struct MetalStreamView: UIViewRepresentable {
	let renderer: MetalRenderer
	let highRefresh: Bool
	let acceptsInput: Bool
	let virtualControls: Bool
	let controlsStyle: VirtualControlsStyle
	let videoAspectForLetterbox: CGFloat?
	let onFrameGenerationTap: () -> Void
	let onVirtualPad: (VirtualPadState) -> Void
	let onReset: () -> Void
	let onTouch: (ControllerInput.TouchEvent) -> Void
	let onTap: (Int) -> Void
	let onCornerTap: () -> Void
	let onLeftCornerTap: () -> Void

	func makeUIView(context: Context) -> StreamMetalView {
		let view = StreamMetalView(renderer: renderer)
		updateUIView(view, context: context)
		return view
	}

	func updateUIView(_ uiView: StreamMetalView, context: Context) {
		uiView.highRefresh = highRefresh
		uiView.onTouch = onTouch
		uiView.onTap = onTap
		uiView.onCornerTap = onCornerTap
		uiView.onLeftCornerTap = onLeftCornerTap
		uiView.videoAspectForLetterbox = videoAspectForLetterbox
		uiView.onFrameGenerationTap = onFrameGenerationTap
		uiView.onVirtualPad = onVirtualPad
		uiView.onReset = onReset
		uiView.setControlsStyle(controlsStyle)
		uiView.setInputMode(acceptsInput: acceptsInput, virtualControls: virtualControls)
	}
}
