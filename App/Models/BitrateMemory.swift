import Darwin
import Foundation
import Observation

/// How one stream went, for Auto bitrate. Built up second by second while streaming.
struct StreamQualityReport {
	let bitrateMbps: Int
	/// Seconds actually streaming (not paused, not reconnecting)
	let seconds: Int
	let averageLoss: Double
	/// Frames lost or failed to decode
	let lostFrames: Int
	/// The most GeForce NOW actually sent in any second
	let peakMbps: Double
}

/// Auto bitrate: remembers the bitrate that works on each Wi-Fi network, stepping up
/// after clean sessions and down after lossy ones. GeForce NOW fixes the bitrate when a
/// game starts, so learned values are used from the next game.
@Observable
final class BitrateMemory {
	struct Entry: Codable, Equatable {
		var bitrateMbps: Int
		/// A bitrate that dropped video here. Stepping up stays below it until the network proves better.
		var ceilingMbps: Int?
		/// Clean sessions in a row just under the ceiling
		var cleanStreak = 0
	}

	/// Sessions shorter than this don't say much either way
	static let minimumSeconds = 60
	/// Stepping up needs a longer clean session
	static let stepUpSeconds = 180
	/// Auto bitrate doesn't climb past this on its own, unless the Bitrate setting is already higher
	static let autoCap = 75

	private(set) var entries: [String: Entry] = [:]

	@ObservationIgnored private let key = "bitrateMemory"

	init() {
		if let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
		{
			entries = decoded
		}
	}

	func bitrate(for key: String) -> Int? { entries[key]?.bitrateMbps }

	/// The player picked a bitrate for this network (from a connection check): start from it
	func setManual(_ bitrate: Int, for key: String) {
		guard entries[key] != Entry(bitrateMbps: bitrate) else { return }
		entries[key] = Entry(bitrateMbps: bitrate)
		save()
	}

	/// Learns from a finished stream. `starting` is the Bitrate setting, used to allow
	/// climbing past the usual cap when the player already chose more.
	func record(_ report: StreamQualityReport, for key: String, starting: Int) {
		guard report.seconds >= Self.minimumSeconds else { return }
		let rate = report.bitrateMbps
		// From before the player picked a different bitrate: their choice wins
		if let current = entries[key], current.bitrateMbps != rate { return }
		var entry = entries[key] ?? Entry(bitrateMbps: rate)
		let lostPerMinute = Double(report.lostFrames) / (Double(report.seconds) / 60)
		let percent = String(format: "%.2f%%", report.averageLoss * 100)

		if report.averageLoss >= 0.01 || lostPerMinute >= 2 {
			// Lossy: back off a quarter, and don't climb back to this soon
			entry.bitrateMbps = max(10, min(rate - 5, Self.roundDown5(Double(rate) * 0.75)))
			entry.ceilingMbps = rate
			entry.cleanStreak = 0
			log.notice("Auto bitrate: \(rate) Mbps lost \(percent, privacy: .public), \(report.lostFrames) frames in \(report.seconds) s, next time \(entry.bitrateMbps) Mbps")
		} else if report.averageLoss < 0.003, lostPerMinute < 0.5, report.seconds >= Self.stepUpSeconds,
			report.peakMbps >= Double(rate) * 0.6
		{
			// Clean, and the stream really used the bitrate: step up a fifth
			let cap = min(StreamSettings.maxBitrateMbps, max(Self.autoCap, starting), (entry.ceilingMbps ?? .max) - 5)
			let next = min(cap, max(rate + 5, Self.roundDown5(Double(rate) * 1.2)))
			if next > rate {
				entry.bitrateMbps = next
				log.notice("Auto bitrate: \(rate) Mbps was clean for \(report.seconds) s, next time \(next) Mbps")
			} else if entry.ceilingMbps != nil {
				// Sitting just under an old failure: after a few clean sessions, try past it again
				entry.cleanStreak += 1
				if entry.cleanStreak >= 3 {
					entry.ceilingMbps = nil
					entry.cleanStreak = 0
					log.notice("Auto bitrate: \(rate) Mbps clean three times in a row, allowing higher again")
				}
			}
		} else {
			log.notice("Auto bitrate: \(rate) Mbps, no change (\(percent, privacy: .public) loss, \(report.lostFrames) frames, \(report.seconds) s)")
		}

		if entries[key] != entry {
			entries[key] = entry
			save()
		}
	}

	func forgetAll() {
		entries = [:]
		save()
	}

	private func save() {
		if let data = try? JSONEncoder().encode(entries) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}

	private static func roundDown5(_ value: Double) -> Int { Int(value / 5) * 5 }
}

enum LocalNetwork {
	/// The Wi-Fi network the phone is on, as its subnet (e.g. "192.168.50.0/24"), or nil
	/// when it isn't on Wi-Fi. Naming the network (SSID) needs an entitlement and location
	/// access, so the subnet stands in for it. Two places that happen to share a subnet
	/// share a learned bitrate too.
	static func currentKey() -> String? {
		var list: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&list) == 0, let first = list else { return nil }
		defer { freeifaddrs(list) }
		for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
			let entry = pointer.pointee
			guard String(cString: entry.ifa_name) == "en0",
				let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
				let netmask = entry.ifa_netmask
			else { continue }
			let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
			let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
			let network = ip & mask
			let octets = [24, 16, 8, 0].map { String((network >> UInt32($0)) & 0xff) }
			return "\(octets.joined(separator: "."))/\(mask.nonzeroBitCount)"
		}
		return nil
	}
}
