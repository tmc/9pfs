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

	// bundledExtensionURL is the extension embedded in this app bundle, which
	// macOS registers when the app is launched from its installed location.
	static let bundledExtensionURL: URL? = {
		let extensions = Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions")
		let entries = (try? FileManager.default.contentsOfDirectory(
			at: extensions, includingPropertiesForKeys: nil)) ?? []
		return entries.first { url in
			url.pathExtension == "appex" && Bundle(url: url)?.bundleIdentifier == ninepfsBundleID
		}
	}()

	enum Status {
		case checking
		case enabled
		case disabled
		// unverifiable: the extension is present in this app bundle but absent
		// from a module list that names no third-party module at all. On some
		// systems FSClient reports only the system modules, so that combination
		// says nothing about whether the module is registered.
		case unverifiable
		case notInstalled
	}

	var status: Status {
		guard loaded else { return .checking }
		if let ninepfs { return ninepfs.enabled ? .enabled : .disabled }
		let sawThirdParty = modules.contains { !$0.id.hasPrefix("com.apple.") }
		if Self.bundledExtensionURL != nil && !sawThirdParty { return .unverifiable }
		return .notInstalled
	}

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
	let status: ModuleList.Status

	private var color: Color {
		switch status {
		case .checking, .unverifiable: return .secondary
		case .enabled: return .green
		case .disabled, .notInstalled: return .orange
		}
	}

	private var title: String {
		switch status {
		case .checking: return "Checking…"
		case .enabled: return "Enabled"
		case .disabled: return "Disabled"
		case .unverifiable: return "Status unavailable"
		case .notInstalled: return "Not installed"
		}
	}

	private var detail: String {
		switch status {
		case .checking:
			return "Reading FSKit module state."
		case .enabled:
			return "Ready to mount. Use /sbin/mount -F -t 9pfs."
		case .disabled:
			return "Turn on “9pfs” in System Settings > General > Login Items & Extensions > File System Extensions."
		case .unverifiable:
			return "macOS is reporting only its own FSKit modules to this app, so the module's state cannot be read here. If “9pfs” appears in System Settings it is registered; confirm with “pluginkit -mAvvv -p com.apple.fskit.fsmodule” and mount as usual."
		case .notInstalled:
			return "The 9pfs FSKit module is not registered. Copy the app to /Applications and open it once, then enable it in System Settings."
		}
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
			print("fskit: bundled extension: \(ModuleList.bundledExtensionURL?.path ?? "missing")")
			let semaphore = DispatchSemaphore(value: 0)
			FSClient.shared.fetchInstalledExtensions { modules, error in
				if let error {
					print("fskit: fetch installed extensions: \(error)")
				}
				for module in modules ?? [] {
					print("fskit: \(module.bundleIdentifier) enabled=\(module.isEnabled) url=\(module.url.path)")
				}
				if !(modules ?? []).contains(where: { !$0.bundleIdentifier.hasPrefix("com.apple.") }) {
					print("fskit: no third-party module reported; the list is not authoritative here.")
					print("fskit: check registration with: pluginkit -mAvvv -p com.apple.fskit.fsmodule")
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

			StatusBadge(status: moduleList.status)
				.padding(.vertical, 4)
				.textSelection(.enabled)

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
				Text(moduleList.status == .unverifiable
					? "FSKit modules visible to this app (no third-party module is being reported)"
					: "All installed FSKit modules")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
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
		.frame(minWidth: 480, idealWidth: 520, minHeight: 600, idealHeight: 680)
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
