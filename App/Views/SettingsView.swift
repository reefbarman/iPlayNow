import AVFoundation
import CoreHaptics
import SwiftUI

/// Stream settings, shared by the main settings sheet and the in-stream menu.
struct StreamSettingsForm: View {
	@Binding var settings: StreamSettings
	/// Set when the video and network settings shown are this console's own
	var customConsoleName: String?
	/// Overrides the bitrate slider's label, e.g. while streaming on a network with a learned bitrate
	var bitrateTitle: String?
	var showsControllerTest = false
	/// While streaming: called with true when the controller test opens, so the
	/// stream can let go of the controller, and false when it closes
	var onControllerTest: ((Bool) -> Void)?

	@Environment(BitrateMemory.self) private var bitrateMemory

	var body: some View {
		VideoSettingsSection(settings: $settings, customConsoleName: customConsoleName, bitrateTitle: bitrateTitle)

		Section {
			Toggle("Auto bitrate", isOn: $settings.autoBitrate)
			if settings.autoBitrate && !bitrateMemory.entries.isEmpty {
				Button("Forget learned bitrates", role: .destructive) { bitrateMemory.forgetAll() }
			}
		} footer: {
			Text("Remembers the bitrate that works for each console on each Wi-Fi network, so you don't have to keep tuning it. A new network starts at the starting bitrate above. It never changes mid-game.")
			Text("After a few minutes of smooth play it goes up about a fifth next time (up to 100 Mbps, or your starting bitrate if that's higher). After a session that drops video it comes down a quarter. Moving the bitrate slider while you play, or applying an Optimise connection suggestion, sets it for that network.")
		}

		Section {
			SettingsLink(title: "Display", systemImage: "tv", summary: settings.displaySummary) {
				DisplaySettingsPage(settings: $settings)
			}
			SettingsLink(title: "Controller", systemImage: "gamecontroller", summary: settings.controllerSummary) {
				ControllerSettingsPage(settings: $settings, showsControllerTest: showsControllerTest, onControllerTest: onControllerTest)
			}
			SettingsLink(title: "Virtual controls", systemImage: "hand.tap", summary: settings.virtualControlsSummary) {
				VirtualControlsSettingsPage(settings: $settings)
			}
			SettingsLink(title: "Audio", systemImage: "mic", summary: settings.microphone ? "Microphone on" : "Microphone off") {
				AudioSettingsPage(settings: $settings)
			}
			SettingsLink(title: "Network", systemImage: "wifi", summary: settings.networkSummary) {
				NetworkSettingsPage(settings: $settings, customConsoleName: customConsoleName)
			}
			SettingsLink(title: "Debug", systemImage: "ant", summary: settings.frameCapture ? "Frame capture on" : "Off") {
				DebugSettingsPage(settings: $settings)
			}
		}
	}
}

/// One-line summaries of each settings page, shown under its row
private extension StreamSettings {
	static func summary(_ parts: [String?]) -> String {
		parts.compactMap { $0 }.joined(separator: " · ")
	}

	var displaySummary: String {
		let upscaling = upscaling.usesMetalFX && !MetalRenderer.supportsMetalFX ? UpscalingMode.sharp : upscaling
		let hasHighRefresh = UIScreen.main.maximumFramesPerSecond > 60
		return Self.summary([
			displayMode.label,
			upscaling.label,
			hasHighRefresh ? (highRefreshDisplay ? "120 Hz" : "60 Hz") : nil,
			frameGeneration ? "Frame gen" : nil,
			statsMode == .off ? nil : "\(statsMode.label) stats",
		])
	}

	var controllerSummary: String {
		let gyro: String? = switch gyroAim {
		case .off: nil
		case .always: "Gyro aim always"
		case .holdingL2: "Gyro aim on L2"
		case .holdingR1: "Gyro aim on R1"
		}
		return Self.summary([
			rumble ? "Rumble on" : "Rumble off",
			gyro,
			selectIsTouchpad ? "Select is touchpad" : nil,
		])
	}

	var virtualControlsSummary: String {
		guard virtualControls != .never else { return virtualControls.label }
		return Self.summary([
			virtualControls.label,
			controlsSize.label,
			"\(Int((controlsOpacity * 100).rounded()))%",
			fixedSticks ? "Fixed sticks" : nil,
		])
	}

	var networkSummary: String {
		Self.summary([
			networkSmoothing ? "Smoothing on" : "Smoothing off",
			takionV20 ? "Takion v20" : nil,
		])
	}
}

/// A row that opens a settings page. `value` sits on the right, `summary` under the title.
private struct SettingsLink<Destination: View>: View {
	let title: String
	let systemImage: String
	var value: String?
	var summary: String?
	@ViewBuilder var destination: () -> Destination

	var body: some View {
		NavigationLink(destination: destination) {
			LabeledContent {
				if let value { Text(value) }
			} label: {
				Label {
					Text(title)
					if let summary {
						Text(summary)
					}
				} icon: {
					Image(systemName: systemImage)
				}
			}
		}
	}
}

/// A slider with its title and current value above it
private struct LabeledSlider: View {
	let title: String
	@Binding var value: Double
	let range: ClosedRange<Double>
	let step: Double
	let valueText: String

	var body: some View {
		VStack(alignment: .leading) {
			HStack {
				Text(title)
				Spacer()
				Text(valueText).foregroundStyle(.secondary).monospacedDigit()
			}
			Slider(value: $value, in: range, step: step)
		}
	}
}

private extension View {
	func settingsPage(_ title: String) -> some View {
		navigationTitle(title).navigationBarTitleDisplayMode(.inline)
	}
}

private func multiplier(_ value: Double) -> String {
	"\(value.formatted(.number.precision(.fractionLength(0...2))))×"
}

/// Picture fit, upscaling, refresh rate, frame generation and stats
private struct DisplaySettingsPage: View {
	@Binding var settings: StreamSettings

	private var upscalingSelection: Binding<UpscalingMode> {
		Binding(
			get: { settings.upscaling.usesMetalFX && !MetalRenderer.supportsMetalFX ? .sharp : settings.upscaling },
			set: { settings.upscaling = $0 })
	}

	var body: some View {
		Form {
			Section {
				Picker("Picture", selection: $settings.displayMode) {
					ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
				}
			} footer: {
				Text("Fit shows the whole picture, with black bars where the screen is a different shape to 16:9. Zoom fills the screen and crops the overflow.")
			}

			Section {
				Picker("Upscaling", selection: upscalingSelection) {
					ForEach(UpscalingMode.allCases.filter { !$0.usesMetalFX || MetalRenderer.supportsMetalFX }) {
						Text($0.label).tag($0)
					}
				}
			} footer: {
				if MetalRenderer.supportsMetalFX {
					Text("MetalFX Spatial enlarges the picture to the screen's resolution. MetalFX 4K enlarges it to 3840×2160 and then scales it down to the screen, which can look smoother but uses more GPU and battery.")
				}
			}

			Section {
				if UIScreen.main.maximumFramesPerSecond > 60 {
					Toggle("120 Hz screen", isOn: $settings.highRefreshDisplay)
				}
				Toggle("Frame generation (experimental)", isOn: $settings.frameGeneration)
			} header: {
				Text("Smoothness")
			} footer: {
				if UIScreen.main.maximumFramesPerSecond > 60 {
					Text("120 Hz screen gets each frame on screen sooner, for a little more battery.")
				}
				Text("Frame generation makes an extra frame between each pair the PS5 sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay. 60 fps needs the 120 Hz screen. The FG button in the bottom-right corner of the stream turns it on and off.")
			}

			Section {
				Picker("Stats", selection: $settings.statsMode) {
					ForEach(StatsMode.allCases) { Text($0.label).tag($0) }
				}
			} footer: {
				Text("Stats sit in the black bar above the picture. Simple shows the essentials, Advanced shows everything.")
			}
		}
		.settingsPage("Display")
	}
}

/// Vibration, motion, buttons and controller tools
private struct ControllerSettingsPage: View {
	@Binding var settings: StreamSettings
	var showsControllerTest: Bool
	var onControllerTest: ((Bool) -> Void)?
	private static let deviceHasHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

	var body: some View {
		Form {
			Section {
				NavigationLink { ControlsGuideView() } label: {
					Label("Controls Guide", systemImage: "book")
				}
				if showsControllerTest {
					ControllerTestLink(onActiveChange: onControllerTest) {
						Label("Controller Test", systemImage: "dot.radiowaves.left.and.right")
					}
				}
			} footer: {
				Text("Hold Select + Start for a second during a stream to open the menu.")
			}

			Section {
				Toggle("Rumble", isOn: $settings.rumble)
				// iPads have no vibration motor
				if Self.deviceHasHaptics {
					Picker("Phone haptics", selection: $settings.phoneHaptics) {
						ForEach(PhoneHaptics.allCases) { Text($0.label).tag($0) }
					}
					.disabled(!settings.rumble)
				}
			} header: {
				Text("Vibration")
			} footer: {
				if Self.deviceHasHaptics {
					Text("Rumble turns all vibration on or off. Phone haptics sets how strongly the phone itself vibrates, which it does with virtual controls or a controller that has no motors (like a Backbone).")
				} else {
					Text("Rumble turns controller vibration on or off.")
				}
			}

			Section {
				Toggle("\(DeviceLayout.isPad ? "iPad" : "Phone") gyro for motion controls", isOn: $settings.phoneMotion)
				SettingsLink(title: "Gyro aiming", systemImage: "scope", value: settings.gyroAim.label) {
					GyroAimSettingsPage(settings: $settings)
				}
			} header: {
				Text("Motion")
			} footer: {
				Text("Controllers with a gyro (DualSense, DualShock 4, GameSir G8+ in its iOS mode) send their own motion. The \(DeviceLayout.deviceNoun)'s gyro covers virtual controls and controllers without motion sensors, like a Backbone.")
			}

			Section {
				Toggle("Select button is touchpad click", isOn: $settings.selectIsTouchpad)
				if HomeButtonSetting.isSupported {
					Button("Home Button Settings") { HomeButtonSetting.openSettings() }
				}
			} header: {
				Text("Buttons")
			} footer: {
				if HomeButtonSetting.isSupported {
					Text("Home Button Settings opens the iOS setting for what your controller's Home button does in apps. Let apps use it and Home opens the PS5 menu, otherwise iOS opens its Game Overlay. Open it with your controller connected.")
				}
			}
		}
		.settingsPage("Controller")
	}
}

/// Turning controller (or phone) motion into right stick movement, and tuning it to the game
private struct GyroAimSettingsPage: View {
	@Binding var settings: StreamSettings

	var body: some View {
		Form {
			Section {
				Picker("Gyro aiming", selection: $settings.gyroAim) {
					ForEach(GyroAimMode.allCases) { Text($0.label).tag($0) }
				}
			} footer: {
				Text("Turns the controller's motion (or the phone's, if the controller has none) into right stick movement, on top of the stick itself, and stops sending motion to the game.")
			}

			if settings.gyroAim != .off {
				Section {
					Picker("Look left/right by", selection: $settings.gyroAimTurning) {
						ForEach(GyroAimTurning.allCases) { Text($0.label).tag($0) }
					}
					LabeledSlider(title: "Gyro sensitivity", value: $settings.gyroAimSensitivity, range: 0.25...3, step: 0.05,
						valueText: multiplier(settings.gyroAimSensitivity))
					LabeledSlider(title: "Up/down speed", value: $settings.gyroAimVerticalScale, range: 0.5...3, step: 0.05,
						valueText: multiplier(settings.gyroAimVerticalScale))
					Toggle("Invert gyro up/down", isOn: $settings.gyroAimInvertY)
				} header: {
					Text("Aiming")
				} footer: {
					Text("Tilt like a steering wheel or turn left and right to look around (Look left/right by picks which), and tip the top towards or away from you to look up and down.")
					Text("Up/down speed makes looking up and down faster than left and right, as most games turn slower vertically.")
				}

				Section {
					LabeledSlider(title: "Game dead zone", value: $settings.gyroAimDeadzone, range: 0...0.4, step: 0.01,
						valueText: "\(Int((settings.gyroAimDeadzone * 100).rounded()))%")
					Toggle("Dead zone per direction", isOn: $settings.gyroAimPerAxisDeadzone)
				} header: {
					Text("Match the game")
				} footer: {
					Text("Game dead zone is how much stick movement the game ignores. Raise it until small, slow movements move the camera, and lower it if the camera creeps when you're nearly still.")
					Text("Dead zone per direction pushes left/right and up/down past the dead zone separately, so the small part of a diagonal correction isn't lost. Try it if slight up/down adjustments get ignored while moving sideways, or the other way round.")
				}

				Section {
					LabeledSlider(title: "Fine aim boost", value: $settings.gyroAimResponseCurve, range: 1...3, step: 0.1,
						valueText: settings.gyroAimResponseCurve.formatted(.number.precision(.fractionLength(1))))
				} footer: {
					Text("Undoes games slowing down small stick movements. Raise it if small corrections feel sluggish, lower it if they overshoot. 1 turns it off.")
				}
			}
		}
		.settingsPage("Gyro Aiming")
	}
}

/// On-screen controls
private struct VirtualControlsSettingsPage: View {
	@Binding var settings: StreamSettings

	var body: some View {
		Form {
			Section {
				Picker("Show", selection: $settings.virtualControls) {
					ForEach(VirtualControlsMode.allCases) { Text($0.label).tag($0) }
				}
			} footer: {
				Text("Auto shows virtual controls when no supported controller is connected.")
			}

			if settings.virtualControls != .never {
				Section {
					Picker("Size", selection: $settings.controlsSize) {
						ForEach(ControlsSize.allCases) { Text($0.label).tag($0) }
					}
					LabeledSlider(title: "Opacity", value: $settings.controlsOpacity, range: 0.2...1, step: 0.05,
						valueText: "\(Int((settings.controlsOpacity * 100).rounded()))%")
				}

				Section {
					Toggle("Fixed sticks", isOn: $settings.fixedSticks)
				} footer: {
					Text("Sticks normally start wherever your thumb lands in the lower half. Fixed sticks stay in one spot on each side instead, and a touch near one moves it straight away.")
				}
			}
		}
		.settingsPage("Virtual Controls")
	}
}

/// Microphone for game and party chat
private struct AudioSettingsPage: View {
	@Binding var settings: StreamSettings
	@State private var micDenied = AVAudioApplication.shared.recordPermission == .denied

	var body: some View {
		Form {
			Section {
				Toggle("Microphone", isOn: $settings.microphone)
					.onChange(of: settings.microphone) { _, on in
						guard on else { return }
						AVAudioApplication.requestRecordPermission { granted in
							DispatchQueue.main.async {
								micDenied = !granted
								if !granted { settings.microphone = false }
							}
						}
					}
			} footer: {
				if micDenied {
					Text("iPlay5 doesn't have access to the microphone. Turn it on in Settings › Apps › iPlay5.")
				}
				Text("Sends your voice to the PS5 for game and party chat. Tap the mic button in the bottom-left corner of the stream to mute it.")
				Text("On the phone's speaker, echo cancellation stops your party hearing the game. With AirPods or other Bluetooth headphones the phone's mic is used, unless you're on iOS 26 with AirPods that support high-quality recording.")
			}
		}
		.settingsPage("Audio")
	}
}

private struct NetworkSettingsPage: View {
	@Binding var settings: StreamSettings
	var customConsoleName: String?

	var body: some View {
		Form {
			NetworkSettingsSections(settings: $settings, customConsoleName: customConsoleName)
		}
		.settingsPage("Network")
	}
}

private struct DebugSettingsPage: View {
	@Binding var settings: StreamSettings

	var body: some View {
		Form {
			Section {
				Toggle("Frame capture button", isOn: $settings.frameCapture)
			} footer: {
				Text("Adds a button at the bottom left of the stream that saves the last couple of seconds of frames, real and generated, to \(DeviceLayout.filesLocation) › Frame captures. Uses up to about 800 MB of memory while on.")
			}
		}
		.settingsPage("Debug")
	}
}

/// Resolution, frame rate, bitrate, codec and HDR. A console can have its own.
struct VideoSettingsSection: View {
	@Binding var settings: StreamSettings
	var customConsoleName: String?
	var bitrateTitle: String?

	var body: some View {
		Section {
			Picker("Resolution", selection: $settings.resolution) {
				ForEach(StreamResolution.allCases) { Text($0.label).tag($0) }
			}
			Picker("Frame rate", selection: $settings.fps) {
				Text("60 fps").tag(60)
				Text("30 fps").tag(30)
			}
			VStack(alignment: .leading) {
				HStack {
					Text(bitrateTitle ?? (settings.autoBitrate ? "Starting bitrate" : "Bitrate"))
					Spacer()
					Text("\(settings.bitrateMbps) Mbps").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: Binding(get: { Double(settings.bitrateMbps) }, set: { settings.bitrateMbps = Int($0) }), in: 5...200, step: 5)
			}
			Picker("Codec", selection: $settings.codec) {
				ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
			}
			.disabled(settings.hdr)
			Toggle("HDR", isOn: $settings.hdr)
		} header: {
			Text(customConsoleName.map { "Video for \($0)" } ?? "Video")
		} footer: {
			Text("PS5 Remote Play tops out at 1080p60. HDR needs H.265 and HDR turned on in the PS5's video output settings. Changing these reconnects the stream.")
			Text("The PS5 may cap the bitrate below what you ask for, so watch the stats overlay. Above 100 Mbps needs a strong connection (ideally the PS5 on Ethernet and 5 GHz or 6 GHz Wi-Fi) or you may see stutter.")
			if customConsoleName == nil {
				Text("To give one console its own video and network settings, swipe left on it in the console list and tap Settings.")
			}
		}
	}
}

/// Network smoothing and Takion v20. A console can have its own.
struct NetworkSettingsSections: View {
	@Binding var settings: StreamSettings
	var customConsoleName: String?

	var body: some View {
		Section {
			Toggle("Smooth network hiccups", isOn: $settings.networkSmoothing)
		} header: {
			Text(customConsoleName.map { "Network for \($0)" } ?? "Network")
		} footer: {
			Text("For Wi-Fi that stutters. Waits a little longer for late video, keeps the picture moving (briefly smeared) instead of freezing when a frame is lost, and evens out uneven frames by holding one or two back. That adds up to about 17 ms per frame held, only while the network is acting up, and goes back to normal once it's calm. The stats overlay shows what it's doing. Changing this reconnects the stream.")
		}

		Section {
			Toggle("Takion v20 protocol (experimental)", isOn: $settings.takionV20)
		} footer: {
			Text("Offers the PS5 the newer stream protocol that recent official apps use. The PS5 decides; if it doesn't answer, the stream stays on the usual protocol. There's no measured latency gain yet, so compare with it off. The stats overlay shows which one is in use. Changing this reconnects the stream.")
		}
	}
}

/// A console's own video and network settings, for when it's on a different
/// connection to the others (e.g. one on Ethernet, one on Wi-Fi)
struct ConsoleSettingsView: View {
	let consoleID: UUID

	@Environment(ConsoleStore.self) private var consoles
	@Environment(SettingsStore.self) private var store
	@Environment(\.dismiss) private var dismiss
	/// Saved when editing ends rather than per keystroke, so the status poller
	/// doesn't restart for every character
	@State private var remoteHost = ""

	private var console: Console? { consoles.consoles.first { $0.id == consoleID } }

	private func saveRemoteHost() {
		guard var console else { return }
		let trimmed = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
		let value = trimmed.isEmpty ? nil : trimmed
		guard value != console.remoteHost else { return }
		console.remoteHost = value
		consoles.update(console)
	}

	private var custom: Binding<Bool> {
		Binding(
			get: { console?.customSettings != nil },
			set: { on in
				guard var console else { return }
				// Start from the shared settings, so turning it on changes nothing until you edit
				console.customSettings = on ? store.settings.connection : nil
				consoles.update(console)
			})
	}

	/// The shared settings with this console's video and network settings on top.
	/// Edits only keep the video and network part.
	private var settings: Binding<StreamSettings> {
		Binding(
			get: { store.settings.applying(console?.customSettings) },
			set: { new in
				guard var console, console.customSettings != nil else { return }
				console.customSettings = new.connection
				consoles.update(console)
			})
	}

	var body: some View {
		NavigationStack {
			Form {
				if let console {
					Section {
						TextField("IP address or hostname", text: $remoteHost)
							.keyboardType(.URL)
							.textInputAutocapitalization(.never)
							.autocorrectionDisabled()
							.submitLabel(.done)
							.onSubmit(saveRemoteHost)
					} header: {
						Text("Remote address")
					} footer: {
						Text("For playing away from home without PSN. When \(console.name) isn't found on the local network, the app uses this address instead, such as your home's public IP or a dynamic DNS name. Your router needs to forward TCP 9295 and UDP 9295, 9296, 9297 and 9302 to \(console.name), which should have a reserved local IP. IPv4 only.")
					}
					Section {
						Toggle("Custom settings", isOn: custom)
					} footer: {
						Text("Give \(console.name) its own video and network settings, for example when it's on Ethernet and your other console is on Wi-Fi. Display and controller settings are always shared. While you play \(console.name), changes to video and network settings in the stream menu are saved here.")
					}
					if console.customSettings != nil {
						VideoSettingsSection(settings: settings, customConsoleName: console.name)
						NetworkSettingsSections(settings: settings, customConsoleName: console.name)
					}
				}
			}
			.navigationTitle(console?.name ?? "Console")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
		}
		.onAppear { remoteHost = console?.remoteHost ?? "" }
		.onDisappear(perform: saveRemoteHost)
	}
}

struct SettingsView: View {
	@Environment(SettingsStore.self) private var store
	@Environment(ConsoleStore.self) private var consoles
	@Environment(\.dismiss) private var dismiss
	@State private var isPreparingDiagnostics = false
	@State private var diagnosticsShare: DiagnosticsShare?
	@State private var showDiagnosticsError = false

	var body: some View {
		@Bindable var store = store
		NavigationStack {
			Form {
				StreamSettingsForm(settings: $store.settings, showsControllerTest: true)

				Section {
					Button {
						isPreparingDiagnostics = true
					} label: {
						if isPreparingDiagnostics {
							ProgressView("Preparing diagnostics…")
						} else {
							Label("Share diagnostics", systemImage: "ladybug")
						}
					}
					.disabled(isPreparingDiagnostics || diagnosticsShare != nil)
					Link(destination: URL(string: "https://github.com/reefbarman/iPlay5/issues/new")!) {
						Label("Report a problem on GitHub", systemImage: "exclamationmark.bubble")
					}
				} header: {
					Text("Help")
				} footer: {
					Text("The report has your phone model, screen details, settings and the app's logs since it was opened. IP addresses, keys, account IDs and console names are removed. Share it before closing the app, so the logs still cover the problem.")
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
			.task(id: isPreparingDiagnostics) {
				guard isPreparingDiagnostics else { return }
				await prepareDiagnostics()
			}
			.sheet(item: $diagnosticsShare) { share in
				share
			}
			.alert("Couldn't prepare diagnostics", isPresented: $showDiagnosticsError) {
				Button("OK", role: .cancel) {}
			} message: {
				Text("Try sharing diagnostics again.")
			}
		}
	}

	private func prepareDiagnostics() async {
		let report = DiagnosticsReport(
			consoleNames: consoles.consoles.map(\.name),
			settings: store.settings,
			remoteAddresses: consoles.consoles.compactMap(\.remoteAddress)
		)
		do {
			let url = try await report.writeFile()
			guard !Task.isCancelled else { return }
			diagnosticsShare = DiagnosticsShare(url: url)
		} catch {
			guard !Task.isCancelled else { return }
			showDiagnosticsError = true
		}
		isPreparingDiagnostics = false
	}
}

private struct DiagnosticsShare: UIViewControllerRepresentable, Identifiable {
	let url: URL
	var id: URL { url }

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: [url], applicationActivities: nil)
	}

	func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
