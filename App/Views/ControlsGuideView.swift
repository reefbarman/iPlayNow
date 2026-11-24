import SwiftUI

/// How touch, the virtual controls and the stream's hidden corner buttons work
struct ControlsGuideView: View {
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				Text("Controller").font(.headline)
				Text("Your controller works as an Xbox controller in every game. Hold \(ControllerStyle.current.view) + \(ControllerStyle.current.menu) for a second to open the stream menu. The Home button is the Xbox button, which opens GeForce NOW's in-game menu, if iOS lets apps use it (see Settings › Controller).")

				Text("Touch").font(.headline)
				Text("With a controller, tap the picture to click there and drag to drag. With virtual controls, the top half works like a trackpad: drag to move the pointer, tap to click, and tap then drag to hold the button. Either way, press and hold or tap with two fingers to right-click, and drag with two fingers to scroll. Turn this off with Touch as mouse in Settings › Virtual controls.")

				Text("Virtual controls").font(.headline)
				Text("Touch open space on either side of the lower half to start a floating stick, or turn on Fixed sticks to keep them in one place. LS and RS (the stick clicks) sit diagonally inward from the D-pad and face buttons, and View and Menu are at the bottom centre.")

				Text("Stream shortcuts").font(.headline)
				Text("Tap the top-right corner for the stream menu. Tap the top-left corner for the Xbox button, the keyboard and, when it's on, the microphone mute. Tap the bottom-right corner to reveal Frame Generation, then tap again to toggle it.")
			}
			.frame(maxWidth: 680, alignment: .leading)
			.padding()
			.frame(maxWidth: .infinity)
		}
		.navigationTitle("Controls Guide")
		.navigationBarTitleDisplayMode(.inline)
	}
}
