import SwiftUI

/// Version, source link and licences. iPlayNow is AGPL-3.0, so every build links to
/// the exact source it was built from (the release tag, or main for local builds).
enum AppInfo {
	private static let info = Bundle.main.infoDictionary

	static var version: String {
		let short = info?["CFBundleShortVersionString"] as? String ?? "?"
		let build = info?["CFBundleVersion"] as? String ?? "?"
		return "\(short) (\(build))"
	}

	static let repository = URL(string: "https://github.com/reefbarman/iPlayNow")!
	static let newIssue = URL(string: "https://github.com/reefbarman/iPlayNow/issues/new")!

	static var sourceRef: String {
		(info?["IPlayNowSourceRef"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "main"
	}

	static var sourceURL: URL { repository.appending(path: "tree/\(sourceRef)") }
}

/// Something bundled into iPlayNow, with its licence text in Resources/Licenses
struct OpenSourceComponent: Identifiable {
	let name: String
	let license: String
	let notice: String
	let url: URL
	/// File name (without .txt) in App/Resources/Licenses
	let file: String
	var id: String { name }

	static let all: [OpenSourceComponent] = [
		.init(
			name: "iPlayNow", license: "AGPL-3.0-only",
			notice: "Copyright reefbarman and iPlayNow contributors. Shares its player with iPlay5, also AGPL-3.0.",
			url: AppInfo.repository, file: "iPlayNow"),
		.init(
			name: "OpenNOW (iOS)", license: "MIT",
			notice: "Copyright (c) 2025 Zortos. iPlayNow's GeForce NOW streaming code is based on OpenNOW.",
			url: URL(string: "https://github.com/OpenCloudGaming/OpenNOW")!, file: "OpenNOW-iOS"),
		.init(
			name: "OpenNOW (Mac)", license: "MIT",
			notice: "Copyright (c) 2026 OpenCloud. The NVST receiver comes from OpenNOW's native client.",
			url: URL(string: "https://github.com/OpenCloudGaming/OpenNOW-Mac")!, file: "OpenNOW-Mac"),
		.init(
			name: "OpenSSL", license: "Apache-2.0",
			notice: "Copyright The OpenSSL Project Authors. Used for the stream's encryption (DTLS and SRTP).",
			url: URL(string: "https://www.openssl.org")!, file: "OpenSSL"),
		.init(
			name: "usrsctp", license: "BSD-3-Clause",
			notice: "Copyright (c) 2015, Randall Stewart and Michael Tuexen. Carries the stream's control and input channels.",
			url: URL(string: "https://github.com/sctplab/usrsctp")!, file: "usrsctp"),
	]
}

/// Settings › About
struct AboutSection: View {
	var body: some View {
		Section {
			LabeledContent("Version", value: AppInfo.version)
			Link(destination: AppInfo.sourceURL) {
				Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
			}
			.gamepadRow("about.source")
			NavigationLink(value: SettingsPage.licences) {
				Label("Licences", systemImage: "doc.text")
			}
			.gamepadRow(SettingsPage.licences.rowID)
		} header: {
			Text("About")
		} footer: {
			Text("iPlayNow is free software under the GNU Affero General Public License v3. You can get its source, change it and share it under the same licence. Not affiliated with or endorsed by NVIDIA.")
		}
	}
}

struct LicensesView: View {
	var body: some View {
		List(OpenSourceComponent.all) { component in
			NavigationLink { LicenseTextView(component: component) } label: {
				VStack(alignment: .leading) {
					Text(component.name)
					Text(component.license).font(.caption).foregroundStyle(.secondary)
				}
			}
		}
		.navigationTitle("Licences")
		.navigationBarTitleDisplayMode(.inline)
	}
}

private struct LicenseTextView: View {
	let component: OpenSourceComponent

	private var text: String {
		Bundle.main.url(forResource: component.file, withExtension: "txt")
			.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
			?? "The licence text is missing from this build. See \(component.url.absoluteString)."
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				Text(component.notice)
				Link(component.url.absoluteString, destination: component.url)
				Divider()
				Text(text)
					.font(.footnote.monospaced())
					.textSelection(.enabled)
			}
			.padding()
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.navigationTitle(component.name)
		.navigationBarTitleDisplayMode(.inline)
	}
}
