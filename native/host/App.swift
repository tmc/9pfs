@preconcurrency import FSKit
import AppKit
import SwiftUI

@MainActor
final class ModuleList: ObservableObject {
	struct Row: Identifiable, Sendable, Equatable {
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
	nonisolated static let ninepfsBundleID = "dev.tmc.apple.examples.fskit.9pfs.extension"

	var ninepfs: Row? { modules.first { $0.id == Self.ninepfsBundleID } }

	// bundledExtensionURL is the extension embedded in this app bundle, which
	// macOS registers when the app is launched from its installed location.
	nonisolated static let bundledExtensionURL: URL? = {
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

		var label: String {
			switch self {
			case .checking: return "Checking…"
			case .enabled: return "Enabled"
			case .disabled: return "Disabled"
			case .unverifiable: return "Status unavailable"
			case .notInstalled: return "Not installed"
			}
		}
	}

	var status: Status { Self.status(modules: modules, loaded: loaded) }

	nonisolated static func status(modules: [Row], loaded: Bool) -> Status {
		guard loaded else { return .checking }
		if let ninepfs = modules.first(where: { $0.id == ninepfsBundleID }) {
			return ninepfs.enabled ? .enabled : .disabled
		}
		let sawThirdParty = modules.contains { !$0.id.hasPrefix("com.apple.") }
		if bundledExtensionURL != nil && !sawThirdParty { return .unverifiable }
		return .notInstalled
	}

	// diagnostics is what the Copy Diagnostics button puts on the pasteboard.
	// A report that pastes this saves a round trip: the macOS version and the
	// module list together say whether a missing 9pfs row means anything. The
	// app is sandboxed and cannot run pluginkit, so it names the command
	// rather than guessing at registration.
	var diagnostics: String {
		Self.diagnostics(modules: modules, error: error, loaded: loaded)
	}

	nonisolated static func diagnostics(modules: [Row], error: String?, loaded: Bool) -> String {
		var lines = ["9pfs \(ProcessInfo.processInfo.operatingSystemVersionString)"]
		lines.append("app: \(Bundle.main.bundleURL.path)")
		lines.append("bundled extension: \(bundledExtensionURL?.path ?? "missing")")
		lines.append("status: \(status(modules: modules, loaded: loaded).label)")
		if let error {
			lines.append("fetch error: \(error)")
		}
		if loaded {
			lines.append("FSKit modules (\(modules.count)):")
			for module in modules {
				lines.append("  \(module.id) enabled=\(module.enabled) \(module.path)")
			}
		} else {
			lines.append("FSKit modules: not fetched")
		}
		lines.append("registration: pluginkit -mAvvv -p com.apple.fskit.fsmodule")
		return lines.joined(separator: "\n") + "\n"
	}

	// refresh re-reads the module list. userInitiated drives the button's busy
	// state; the poll leaves it alone, because a spinner appearing every two
	// seconds reads as the window flickering rather than as progress.
	func refresh(userInitiated: Bool = false) {
		if userInitiated {
			loading = true
		}
		FSClient.shared.fetchInstalledExtensions { modules, error in
			let rows = (modules ?? []).map { module in
				Row(id: module.bundleIdentifier, enabled: module.isEnabled, path: module.url.path)
			}
			DispatchQueue.main.async {
				// Every assignment here is guarded, because @Published
				// republishes whenever it is assigned — the same value still
				// redraws the window. A poll that finds nothing changed has to
				// touch nothing at all, or the redraw it forces every two
				// seconds is visible as a flicker.
				if userInitiated {
					self.loading = false
				}
				if !self.loaded {
					self.loaded = true
				}
				if let error {
					let text = String(describing: error)
					if self.error != text {
						self.error = text
						print("fskit: fetch installed extensions: \(error)")
					}
					return
				}
				if self.modules != rows {
					self.modules = rows
					for module in rows {
						print("fskit: \(module.id) enabled=\(module.enabled) url=\(module.path)")
					}
				}
				if self.error != nil {
					self.error = nil
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

	private var detail: String {
		switch status {
		case .checking:
			return "Checking whether the 9pfs file system is switched on."
		case .enabled:
			return "9pfs is ready. To see it work, run the bundled demo server in Terminal — it prints the mount command for itself:"
		case .disabled:
			return "9pfs is installed but switched off. Open System Settings below and turn on “9pfs” under File System Extensions."
		case .unverifiable:
			return "macOS is telling this app about its own file systems only, so 9pfs cannot report whether it is switched on. Mounting still works. If “9pfs” appears in System Settings, it is installed correctly."
		case .notInstalled:
			return "9pfs is not registered with macOS yet. Move this app to your Applications folder and open it again, then turn on “9pfs” in System Settings."
		}
	}

	// command is the one thing a person needs to copy once 9pfs is working, so
	// it is the demo server rather than a mount: mounting needs a 9P server to
	// point at, and every failure that comes of not having one — "Connection
	// refused" from a dead address, "invalid file system" from a missing mount
	// point — reads as a broken file system rather than a missing argument. The
	// demo has no such failure mode, and prints the mount command for its own
	// address once it is listening.
	//
	// The path is the running bundle's, not a hardcoded /Applications, so it is
	// correct wherever the app was opened from.
	private var command: String? {
		guard status == .enabled else { return nil }
		let demo = Bundle.main.bundleURL
			.appendingPathComponent("Contents/MacOS/9pdemo").path
		return demo.contains(" ") ? "'\(demo)'" : demo
	}

	private var hint: String? {
		switch status {
		case .enabled:
			return "The demo serves a few sample files from a temporary folder, and removes it when you stop the server. To mount a server of your own instead, put its address in the command the demo prints."
		case .unverifiable:
			// Here the actionable step is checking whether the download arrived
			// intact, not anything about FSKit.
			return "A copy damaged in transit also looks like this. Re-download the disk image if mounting fails."
		default:
			return nil
		}
	}

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Circle()
				.fill(color)
				.frame(width: 12, height: 12)
				.padding(.top, 4)
			VStack(alignment: .leading, spacing: 4) {
				Text(status.label)
					.font(.headline)
				Text(detail)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				if let command {
					Text(command)
						.font(.system(.caption, design: .monospaced))
						.textSelection(.enabled)
						.padding(.vertical, 4)
						.padding(.horizontal, 6)
						.background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
				}
				if let hint {
					Text(hint)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
	}
}

@main
struct NinePFSHostApp: App {
	@StateObject private var moduleList = ModuleList()

	init() {
		// --fskit-probe prints what the Copy Diagnostics button copies, for a
		// report made from a terminal. It cannot drive ModuleList.refresh:
		// there is no run loop yet to deliver its main-queue callback.
		if CommandLine.arguments.contains("--fskit-probe") {
			var rows: [ModuleList.Row] = []
			var failure: String?
			let semaphore = DispatchSemaphore(value: 0)
			FSClient.shared.fetchInstalledExtensions { modules, error in
				rows = (modules ?? []).map {
					ModuleList.Row(id: $0.bundleIdentifier, enabled: $0.isEnabled, path: $0.url.path)
				}
				if let error {
					failure = String(describing: error)
				}
				semaphore.signal()
			}
			let fetched = semaphore.wait(timeout: .now() + 10) == .success
			print(ModuleList.diagnostics(modules: rows, error: failure, loaded: fetched), terminator: "")
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
	// copied briefly relabels the diagnostics button, which otherwise gives no
	// sign that anything happened.
	@State private var copied = false

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
			Text("Lets this Mac mount 9P file servers as volumes. Keep this app in your Applications folder — it carries the file system itself.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			StatusBadge(status: moduleList.status)
				.padding(.vertical, 4)
				.textSelection(.enabled)

			HStack(spacing: 12) {
				Button("Open System Settings") {
					openFSKitSettings()
				}
				// The label stays "Refresh" whatever the state: swapping in a
				// spinner resizes the button, and the row jumps with it.
				Button("Refresh") {
					moduleList.refresh(userInitiated: true)
				}
				.disabled(moduleList.loading)
				Button(copied ? "Copied" : "Copy Diagnostics") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(moduleList.diagnostics, forType: .string)
					copied = true
					Task {
						try? await Task.sleep(for: .seconds(2))
						copied = false
					}
				}
				.disabled(!moduleList.loaded)
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
					? "File system extensions this app can see. It is not being told about any third-party ones, including its own."
					: "File system extensions installed on this Mac")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				// A plain stack rather than a List: the list never scrolls (a Mac
				// has a handful of these), and a List would claim the window's
				// remaining height instead of letting it close up around the
				// content.
				VStack(alignment: .leading, spacing: 6) {
					ForEach(moduleList.modules) { module in
						HStack(alignment: .top, spacing: 8) {
							Circle()
								.fill(module.enabled ? Color.green : Color.orange)
								.frame(width: 8, height: 8)
								.padding(.top, 5)
							VStack(alignment: .leading, spacing: 1) {
								Text(module.id == ModuleList.ninepfsBundleID ? "\(module.id) — this app" : module.id)
									.font(.callout)
								Text(module.path)
									.font(.caption)
									.foregroundStyle(.secondary)
									.lineLimit(1)
									.truncationMode(.middle)
							}
						}
					}
				}
				.textSelection(.enabled)
			}

			Spacer(minLength: 0)
		}
		.padding(24)
		.frame(minWidth: 520, idealWidth: 560)
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
