@preconcurrency import FSKit
import AppKit
import SwiftUI

@MainActor
final class ModuleList: ObservableObject {
	struct Row: Identifiable, Sendable {
		let id: String
		let enabled: Bool
		let path: String
	}

	@Published var modules: [Row] = []
	@Published var error: String?
	@Published var loading = false
	// loaded is false until the first fetch returns, so the UI can tell
	// "not checked yet" apart from "checked, found nothing".
	@Published var loaded = false

	// ninepfsBundleID is this app's extension; the UI highlights it among any
	// other installed FSKit modules.
	static let ninepfsBundleID = "dev.tmc.apple.examples.fskit.9pfs.extension"

	var ninepfs: Row? { modules.first { $0.id == Self.ninepfsBundleID } }

	func refresh() {
		loading = true
		FSClient.shared.fetchInstalledExtensions { modules, error in
			let rows = (modules ?? []).map { module in
				Row(id: module.bundleIdentifier, enabled: module.isEnabled, path: module.url.path)
			}
			DispatchQueue.main.async {
				self.loading = false
				self.loaded = true
				if let error {
					self.error = String(describing: error)
					print("fskit: fetch installed extensions: \(error)")
					return
				}
				// Log only on change: refresh runs on a poll, so logging every
				// fetch would flood the unified log.
				let changed = rows.map(\.id) != self.modules.map(\.id)
					|| rows.map(\.enabled) != self.modules.map(\.enabled)
				self.modules = rows
				self.error = nil
				if changed {
					for module in rows {
						print("fskit: \(module.id) enabled=\(module.enabled) url=\(module.path)")
					}
				}
			}
		}
	}
}

private func openFSKitSettings() {
	if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule") {
		NSWorkspace.shared.open(url)
	}
}

// StatusBadge shows the 9pfs extension's enabled state at a glance: a colored
// dot plus a one-line summary that updates as the state is re-fetched.
private struct StatusBadge: View {
	let module: ModuleList.Row?
	let loaded: Bool

	private var color: Color {
		guard loaded else { return .secondary }
		guard let module else { return .orange }
		return module.enabled ? .green : .orange
	}

	private var title: String {
		guard loaded else { return "Checking…" }
		guard let module else { return "Not installed" }
		return module.enabled ? "Enabled" : "Disabled"
	}

	private var detail: String {
		guard loaded else { return "Reading FSKit module state." }
		guard let module else {
			return "The 9pfs FSKit module is not registered. Open the app once, then enable it in System Settings."
		}
		return module.enabled
			? "Ready to mount. Use /sbin/mount -F -t 9pfs."
			: "Turn on “9pfs” in System Settings > General > Login Items & Extensions > File System Extensions."
	}

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Circle()
				.fill(color)
				.frame(width: 12, height: 12)
				.padding(.top, 4)
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.headline)
				Text(detail)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}

@main
struct NinePFSHostApp: App {
	@StateObject private var moduleList = ModuleList()

	init() {
		if CommandLine.arguments.contains("--fskit-probe") {
			let semaphore = DispatchSemaphore(value: 0)
			FSClient.shared.fetchInstalledExtensions { modules, error in
				if let error {
					print("fskit: fetch installed extensions: \(error)")
				}
				for module in modules ?? [] {
					print("fskit: \(module.bundleIdentifier) enabled=\(module.isEnabled) url=\(module.url.path)")
				}
				semaphore.signal()
			}
			_ = semaphore.wait(timeout: .now() + 10)
			exit(0)
		}
		if CommandLine.arguments.contains("--open-fskit-settings") {
			openFSKitSettings()
			exit(0)
		}
	}

	var body: some Scene {
		WindowGroup {
			ContentView(moduleList: moduleList)
		}
	}
}

private struct ContentView: View {
	@ObservedObject var moduleList: ModuleList

	// FSKit posts no public notification when an extension is enabled or
	// disabled, so the app re-fetches on the moments the user is most likely to
	// have changed it: when this app returns to the foreground after a trip to
	// System Settings, and on a slow poll while the window is visible (so a
	// side-by-side toggle is reflected without a manual refresh).
	private let pollTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()
	private let didBecomeActive = NotificationCenter.default
		.publisher(for: NSApplication.didBecomeActiveNotification)

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("9pfs")
				.font(.largeTitle)
			Text("Mounts a 9P server through macOS FSKit. The module lives in the bundled app extension.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			StatusBadge(module: moduleList.ninepfs, loaded: moduleList.loaded)
				.padding(.vertical, 4)

			HStack(spacing: 12) {
				Button("Open System Settings") {
					openFSKitSettings()
				}
				Button {
					moduleList.refresh()
				} label: {
					if moduleList.loading {
						ProgressView()
							.controlSize(.small)
					} else {
						Text("Refresh")
					}
				}
				.disabled(moduleList.loading)
			}

			if let error = moduleList.error {
				Text(error)
					.font(.caption)
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
			}

			if moduleList.modules.count > 1 || (moduleList.ninepfs == nil && !moduleList.modules.isEmpty) {
				Divider()
				Text("All installed FSKit modules")
					.font(.caption)
					.foregroundStyle(.secondary)
				List(moduleList.modules) { module in
					HStack(spacing: 8) {
						Circle()
							.fill(module.enabled ? Color.green : Color.orange)
							.frame(width: 8, height: 8)
						VStack(alignment: .leading) {
							Text(module.id)
							Text(module.path)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
				}
				.frame(minHeight: 120)
			}

			Spacer(minLength: 0)
		}
		.padding(24)
		.frame(minWidth: 620, minHeight: 360)
		.task {
			moduleList.refresh()
		}
		.onReceive(didBecomeActive) { _ in
			moduleList.refresh()
		}
		.onReceive(pollTimer) { _ in
			if !moduleList.loading {
				moduleList.refresh()
			}
		}
	}
}
