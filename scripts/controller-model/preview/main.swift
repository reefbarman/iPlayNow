// Renders the Controller Test's 3D controllers to PNGs on a Mac, to check the models and
// materials without a phone (see scripts/controller-model/README.md):
//
//     swiftc -O App/Views/ControllerScene.swift scripts/controller-model/preview/main.swift -o build/preview-bin/controller-preview
//     build/preview-bin/controller-preview App/Resources build/preview-out
import AppKit
import Metal
import SceneKit
import simd

let args = CommandLine.arguments
guard args.count == 3 else {
	print("usage: controller-preview resources-dir out-dir")
	exit(1)
}
let resources = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for model in [ControllerScene.Model.xbox, .dualSense] {
	let url = resources.appendingPathComponent(model.resourceName + ".usdz")
	guard let controller = ControllerScene(model: model, url: url) else {
		print("couldn't load", url.path)
		exit(1)
	}
	let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
	renderer.scene = controller.scene
	renderer.pointOfView = controller.cameraNode
	let prefix = model.resourceName + "-"

	func save(_ name: String, _ state: ControllerScene.State, time: TimeInterval = 0, light: Bool = false) {
		// Like the app in dark mode, or light mode's grouped background
		controller.scene.background.contents = light
			? NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1) : NSColor(white: 0, alpha: 1)
		controller.apply(state, time: time)
		let image = renderer.snapshot(atTime: time, with: CGSize(width: 900, height: 600), antialiasingMode: .multisampling4X)
		guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
			let png = rep.representation(using: .png, properties: [:]) else { return }
		try? png.write(to: out.appendingPathComponent(prefix + name + ".png"))
		print("wrote", prefix + name)
	}

	let rest = ControllerScene.State()
	save("rest", rest)
	save("rest-light", rest, light: true)

	var pressed = ControllerScene.State()
	pressed.pressed = [.a, .y, .up, .lb, .home, .view, .rightStick, .touchpad]
	pressed.leftStick = SIMD2(0.8, -0.6)
	pressed.lt = 1
	pressed.lightbar = CGColor(srgbRed: 0.2, green: 0.4, blue: 1, alpha: 1)
	pressed.player = 3
	pressed.touches = [.init(x: 0.25, y: 0.4, fromScreen: true), .init(x: 0.75, y: 0.7, fromScreen: false)]
	save("pressed", pressed)

	// Fingers swiping across the touchpad, then a snapshot of the trail
	var swipe = ControllerScene.State()
	for frame in 0...45 {
		let f = Float(frame) / 45
		swipe.touches = [
			.init(x: 0.1 + 0.8 * f, y: 0.5 + 0.3 * sin(f * 6), fromScreen: true),
			.init(x: 0.8 - 0.5 * f, y: 0.2 + 0.1 * f, fromScreen: false),
		]
		controller.apply(swipe, time: 10 + Double(frame) / 60)
	}
	save("swipe", swipe, time: 10.75)

	var turned = pressed
	turned.orientation = simd_quatf(angle: 0.5, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: -0.6, axis: SIMD3(0, 1, 0))
	turned.buzz = .init(left: 1, right: 1, hz: 16)
	turned.triggerLook = .resistance
	save("turned", turned, time: 0.13)

	// From above and behind, to check the shoulders, triggers and their glows
	var top = pressed
	top.pressed.insert(.rb)
	top.rt = 0
	top.triggerRumble = SIMD2(0, 1)
	top.orientation = simd_quatf(angle: 1.1, axis: SIMD3(1, 0, 0))
	save("top", top, time: 0.02)
}
