import GameController
import OSLog
import UIKit

/// A plain-text report people can attach to a GitHub issue: app, phone and screen details,
/// settings, and the app's logs since it was opened. IP and MAC addresses, IDs, tokens, keys and
/// the account's name and email are taken out before sharing.
struct DiagnosticsReport {
	let settings: StreamSettings
	/// Membership and provider, which are useful and not identifying
	var membership: String?
	var provider: String?
	/// The account's name and email, removed wherever they appear
	var privateText: [String] = []

	func writeFile() async throws -> URL {
		let summary = await MainActor.run { Self.summary(settings: settings, membership: membership, provider: provider) }
		let logs = (try? Self.logLines()) ?? ["(couldn't read the app's logs)"]
		let text = redact(summary + "\n\n== Log since the app was opened ==\n" + logs.joined(separator: "\n") + "\n")

		let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("iPlayNow-diagnostics-\(stamp).txt")
		try text.write(to: url, atomically: true, encoding: .utf8)
		return url
	}

	// MARK: - Contents

	@MainActor
	private static func summary(settings: StreamSettings, membership: String?, provider: String?) -> String {
		let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
		let screen = scene?.screen
		let window = scene?.keyWindow?.bounds.size ?? .zero
		let controllers = GCController.controllers().map { "\($0.vendorName ?? "?") (\($0.productCategory))" }
		let settingsJSON = (try? JSONEncoder().encode(settings)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"

		return """
		== iPlayNow diagnostics ==
		App: \(AppInfo.version), source \(AppInfo.sourceRef)
		iOS: \(UIDevice.current.systemVersion)
		Model: \(DeviceLayout.modelIdentifier)
		Screen: \(size(screen?.bounds.size))pt, \(size(screen?.nativeBounds.size))px, scale \(screen?.scale ?? 0), native scale \(screen?.nativeScale ?? 0), max \(screen?.maximumFramesPerSecond ?? 0) Hz, EDR headroom \(screen?.potentialEDRHeadroom ?? 0)
		Window: \(size(window))pt, \(orientation(scene?.interfaceOrientation))
		Foldable: \(DeviceLayout.isFoldable), inner screen: \(DeviceLayout.isInnerScreen(window))
		Controllers: \(controllers.isEmpty ? "none" : controllers.joined(separator: ", "))
		GeForce NOW: \(membership ?? "not signed in")\(provider.map { " via \($0)" } ?? "")
		Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue), Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)
		Settings: \(settingsJSON)
		"""
	}

	private static func logLines() throws -> [String] {
		let store = try OSLogStore(scope: .currentProcessIdentifier)
		let entries = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", logSubsystem))
		let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
			"\(entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))) [\(entry.category)] \(level(entry.level)) \(entry.composedMessage)"
		}
		return Array(lines.suffix(5000))
	}

	// MARK: - Redaction

	private static let redactions: [(pattern: String, replacement: String)] = [
		(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
		// Access and ID tokens (JWTs)
		(#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)?"#, "<token>"),
		// MAC and IPv6 addresses (hex groups split by colons)
		(#"\b[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{0,4}){4,7}\b"#, "<address>"),
		(#"\b\d{1,3}(\.\d{1,3}){3}\b"#, "<ip>"),
		// Session, client and device ids
		(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<id>"),
		// Keys, device hashes and other long hex
		(#"\b[0-9A-Fa-f]{12,}\b"#, "<hex>"),
		// Other base64 blobs (a digit is required so long words survive)
		(#"(?=[A-Za-z+/]*\d)[A-Za-z0-9+/]{16,}={0,2}"#, "<base64>"),
	]

	private func redact(_ text: String) -> String {
		var text = text
		// Longest first, so a full name goes before a part of it
		for value in privateText.sorted(by: { $0.count > $1.count }) where value.count >= 3 {
			text = text.replacingOccurrences(of: value, with: "<account>", options: .caseInsensitive)
		}
		for (pattern, replacement) in Self.redactions {
			text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
		}
		return text
	}

	// MARK: - Formatting

	private static func size(_ size: CGSize?) -> String {
		guard let size else { return "?" }
		return "\(Int(size.width))x\(Int(size.height))"
	}

	private static func orientation(_ orientation: UIInterfaceOrientation?) -> String {
		switch orientation {
		case .portrait: "portrait"
		case .portraitUpsideDown: "portrait upside down"
		case .landscapeLeft: "landscape left"
		case .landscapeRight: "landscape right"
		default: "unknown"
		}
	}

	private static func level(_ level: OSLogEntryLog.Level) -> String {
		switch level {
		case .debug: "debug"
		case .info: "info"
		case .notice: "notice"
		case .error: "ERROR"
		case .fault: "FAULT"
		default: "-"
		}
	}
}
