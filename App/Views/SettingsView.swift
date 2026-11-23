import CoreHaptics
import SwiftUI

/// Stream settings, shared by the main settings sheet and the in-stream menu.
struct StreamSettingsForm: View {
	@Binding var settings: StreamSettings
	/// In the stream menu: video changes apply from the next game
	var streaming = false

	var body: some View {
		VideoSettingsSection(settings: $settings, streaming: streaming)

		Section {
			SettingsLink(title: "Display", systemImage: "tv", summary: settings.displaySummary) {
				DisplaySettingsPage(settings: $settings)
			}
			SettingsLink(title: "Controller", systemImage: "gamecontroller", summary: settings.controllerSummary) {
				ControllerSettingsPage(settings: $settings)
			}
			SettingsLink(title: "Virtual controls", systemImage: "hand.tap", summary: settings.virtualControlsSummary) {
				VirtualControlsSettingsPage(settings: $settings)
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
		case .holdingLT: "Gyro aim on LT"
		case .holdingRB: "Gyro aim on RB"
		}
		return Self.summary([rumble ? "Rumble on" : "Rumble off", gyro])
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
				Text("Frame generation makes an extra frame between each pair the stream sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay. 60 fps needs the 120 Hz screen. The FG button in the bottom-right corner of the stream turns it on and off.")
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

/// Vibration and gyro aiming
private struct ControllerSettingsPage: View {
	@Binding var settings: StreamSettings
	private static let deviceHasHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

	var body: some View {
		Form {
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
				SettingsLink(title: "Gyro aiming", systemImage: "scope", value: settings.gyroAim.label) {
					GyroAimSettingsPage(settings: $settings)
				}
			} header: {
				Text("Motion")
			} footer: {
				Text("Hold View + Menu for a second during a stream to open the menu.")
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
				Text("Turns the controller's motion (or the phone's, if the controller has none) into right stick movement, on top of the stick itself.")
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
					Text("Dead zone per direction pushes left/right and up/down past the dead zone separately, so the small part of a diagonal correction isn't lost.")
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

/// Resolution, frame rate, bitrate and codec: what to ask GeForce NOW for
struct VideoSettingsSection: View {
	@Binding var settings: StreamSettings
	var streaming = false

	var body: some View {
		Section {
			Picker("Resolution", selection: $settings.resolution) {
				ForEach(StreamResolution.allCases) { Text($0.label).tag($0) }
			}
			Picker("Frame rate", selection: $settings.fps) {
				ForEach(StreamSettings.fpsOptions.reversed(), id: \.self) { Text("\($0) fps").tag($0) }
			}
			VStack(alignment: .leading) {
				HStack {
					Text("Maximum bitrate")
					Spacer()
					Text("\(settings.bitrateMbps) Mbps").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: Binding(get: { Double(settings.bitrateMbps) }, set: { settings.bitrateMbps = Int($0) }),
					in: 5...Double(StreamSettings.maxBitrateMbps), step: 5)
			}
			Picker("Codec", selection: $settings.codec) {
				ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
			}
		} header: {
			Text("Video")
		} footer: {
			Text("Your membership decides the most GeForce NOW will stream. 1440p and 120 fps need Ultimate.")
			if streaming {
				Text("Changes here apply from the next game.")
			}
		}
	}
}

/// Account first, then the stream settings
struct SettingsView: View {
	@Environment(SettingsStore.self) private var store
	@Environment(GFNAccountStore.self) private var accounts
	@Environment(\.dismiss) private var dismiss
	@State private var confirmSignOut = false

	var body: some View {
		@Bindable var store = store
		NavigationStack {
			Form {
				if let account = accounts.account {
					Section {
						LabeledContent("Signed in as", value: account.displayName)
						if let email = account.email {
							LabeledContent("Email", value: email)
						}
						LabeledContent("Membership", value: account.tierName ?? "Unknown")
						LabeledContent("Provider", value: account.provider.displayName)
						Button("Sign out", role: .destructive) { confirmSignOut = true }
					} header: {
						Text("Account")
					}
				}

				StreamSettingsForm(settings: $store.settings)
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
			.task { await accounts.refreshTier() }
			.confirmationDialog("Sign out of GeForce NOW?", isPresented: $confirmSignOut, titleVisibility: .visible) {
				Button("Sign out", role: .destructive) {
					accounts.signOut()
					GFNLibrary.clearCache()
					dismiss()
				}
			}
		}
	}
}
