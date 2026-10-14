import SwiftUI
import AppKit
import Foundation
import MantisCore

struct VersionManagementView: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject private var preferences: InterfacePreferences
    @State private var checking = false
    @State private var downloading = false
    @State private var installing = false
    @State private var checked = false
    @State private var release: GUIRelease?
    @State private var latestVersion: String?
    @State private var latestCLI: String?
    @State private var checkedCLI = false
    @State private var status: String?
    @State private var cliVersion: String?
    @State private var detectedCLIPath: String?
    @State private var cliProbePending = true

    private let releasesURL = URL(string: "https://github.com/liuchzzyy/spectromicroscopy/releases")!
    private var currentGUI: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func tr(_ key: String) -> String {
        InterfaceText.value(key, language: preferences.language)
    }

    private func trFormat(_ format: String, _ arg: String) -> String {
        let pattern = tr(format)
        return String(format: pattern, arg)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                versionCard(
                    title: tr("Desktop GUI"),
                    symbol: "macwindow",
                    detail: tr("Mantis.app · native interface"),
                    installed: currentGUI,
                    latest: latestVersion ?? (checked ? tr("Unavailable") : tr("Not checked")),
                    isLatest: latestVersion != nil && currentGUI == latestVersion
                )

                cliCard

                checkAndInstallCard

                if let notes = release?.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(tr("Release Notes")).font(.headline)
                        Divider()
                        Text(notes).textSelection(.enabled).font(.callout)
                    }.padding(20).surface()
                }

                Link(tr("View all Releases in browser"), destination: releasesURL)
                    .font(.caption)
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(Theme.contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await refreshCLI()
        }
    }

    private var cliCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(tr("Command Line (CLI)"), systemImage: "terminal").font(.headline)
                Spacer()
                if let cliVersion, let latestCLI, cliVersion == latestCLI {
                    Label(tr("Latest Version"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            HStack(spacing: 8) {
                Text(tr("Location:")).font(.caption).foregroundStyle(.secondary)
                Text(detectedCLIPath ?? "/Users/liuchzzyy/CodeSpace/spectromicroscopy/mantis_xray")
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(tr("Change Path…")) { chooseCLIPath() }
                    .controlSize(.small)
                if preferences.cliPath != nil {
                    Button(tr("Reset")) {
                        preferences.cliPath = nil
                        Task { await refreshCLI() }
                    }
                    .controlSize(.small)
                }
            }
            Divider()
            HStack {
                versionValue(tr("Current Version"), cliVersion ?? (cliProbePending ? tr("Detecting…") : tr("Not detected")))
                Divider().frame(height: 44)
                versionValue(tr("Latest Version"), latestCLI ?? (checkedCLI ? tr("Unavailable") : tr("Not checked")))
            }
        }
        .padding(20)
        .surface()
    }

    private var checkAndInstallCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("Check & Install")).font(.headline)
                Spacer()
                Button(tr("Check for Updates"), systemImage: "arrow.clockwise") {
                    Task { await check() }
                }
                .disabled(checking || downloading || installing)
            }
            Divider()
            if checking {
                ProgressView(tr("Checking GitHub Releases…")).controlSize(.small)
            }
            if installing {
                ProgressView(tr("Downloading and verifying update…")).controlSize(.small)
            }
            if downloading {
                ProgressView(tr("Downloading and verifying DMG…")).controlSize(.small)
            }
            if let status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            if let current = release, GUIRelease.isNewer(current.version, than: currentGUI) {
                HStack(spacing: 12) {
                    Button(trFormat("Update MANTiS to %@…", current.version)) {
                        Task { await install(current) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(checking || downloading || installing || model.busy)

                    Button(tr("Download verified DMG…"), systemImage: "arrow.down.circle") {
                        Task { await download(current) }
                    }
                    .disabled(checking || downloading || installing)

                    Link(tr("View Release"), destination: current.url)
                }
            }
            Text(tr("The CLI is installed and updated separately; GUI updates replace only the app and its private engine."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .surface()
    }

    private func versionCard(title: String, symbol: String, detail: String, installed: String, latest: String, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                if isLatest {
                    Label(tr("Latest Version"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                versionValue(tr("Current Version"), installed)
                Divider().frame(height: 44)
                versionValue(tr("Latest Version"), latest)
            }
        }
        .padding(20)
        .surface()
    }

    private func versionValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshCLI() async {
        cliProbePending = true
        let candidate = CLIVersion.candidate(preferredPath: preferences.cliPath)
        detectedCLIPath = candidate?.path
        cliVersion = await Task.detached(priority: .utility) {
            candidate.flatMap(CLIVersion.read)
        }.value
        cliProbePending = false
    }

    private func chooseCLIPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Select")
        if panel.runModal() == .OK, let url = panel.url {
            preferences.cliPath = url.path
            Task { await refreshCLI() }
        }
    }

    private func install(_ selected: GUIRelease) async {
        guard !installing, !checking, !downloading, !model.busy else { return }
        let alert = NSAlert()
        alert.messageText = String(format: tr("Updating MANTiS to %@?"), selected.version)
        alert.informativeText = tr("After downloading and verifying the update package, MANTiS will quit, back up the old version, replace the GUI and private engine, and relaunch. Scientific data will not be modified by the updater.")
        alert.addButton(withTitle: tr("Confirm Update"))
        alert.addButton(withTitle: tr("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        installing = true
        status = nil
        do {
            let currentApp = Bundle.main.bundleURL
            guard currentApp.standardizedFileURL.path == "/Applications/Mantis.app" else {
                throw UpdateInstaller.Failure(tr("Automatic update only supports /Applications/Mantis.app. Please install Mantis.app into Applications or download the DMG manually."))
            }
            let helper = currentApp.appendingPathComponent("Contents/Helpers/MantisUpdater")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw UpdateInstaller.Failure(tr("Current installation is missing the update helper; please install the new version manually."))
            }
            let readyRelease = await selected.resolveDigest()
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await UpdateInstaller.prepare(readyRelease, helper: helper)
            }.value

            guard !model.busy else {
                try? FileManager.default.removeItem(at: prepared.app.deletingLastPathComponent())
                throw UpdateInstaller.Failure(tr("Analysis work was started during download; please complete it and retry."))
            }

            let report = UpdateInstaller.resultURL
            try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: report)

            try UpdateInstaller.handoff(prepared, target: currentApp, version: selected.version, report: report)
            await model.close()
            NSApp.terminate(nil)
        } catch {
            status = tr("Update failed: ") + error.localizedDescription
            installing = false
        }
    }

    private func download(_ selected: GUIRelease) async {
        guard !checking, !downloading, !installing, release?.tag == selected.tag,
              GUIRelease.isNewer(selected.version, than: currentGUI) else { return }
        let readyRelease = await selected.resolveDigest()
        guard readyRelease.sha256 != nil else {
            status = tr("Release has no SHA-256 digest; verified download is unavailable.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = readyRelease.dmgURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            status = tr("Destination already exists. Select a new filename; existing files are never replaced.")
            return
        }
        downloading = true
        status = nil
        defer { downloading = false }
        do {
            try await VerifiedUpdateDownload.save(readyRelease, to: destination)
            status = tr("Verified DMG saved to: ") + destination.path
        } catch {
            status = tr("Download failed: ") + error.localizedDescription
        }
    }

    private func check() async {
        guard !checking else { return }
        checking = true; checked = false; release = nil; status = nil
        latestVersion = nil; latestCLI = nil; checkedCLI = false
        defer { checking = false; checked = true }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/liuchzzyy/spectromicroscopy/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MantisNative", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw VersionError.unavailable
            }
            var latest = try GUIRelease.parse(data)
            if latest.sha256 == nil {
                latest = await latest.resolveDigest()
            }
            release = latest
            latestVersion = latest.version

            async let cliFetch = ReleaseCLIVersion.fetch(tag: latest.tag)
            latestCLI = await cliFetch
            checkedCLI = true

            if GUIRelease.isNewer(latest.version, than: currentGUI) {
                status = String(format: tr("New version %@ is available; updating will replace the GUI and bundled engine."), latest.version)
            } else if GUIRelease.isNewer(currentGUI, than: latest.version) {
                status = String(format: tr("Installed GUI is newer than public Release (%@); downgrade is not offered."), latest.version)
            } else {
                status = String(format: tr("You are on the latest version (%@)"), latest.version)
            }
        } catch {
            status = tr("Update check unavailable: ") + error.localizedDescription
            latestCLI = await ReleaseCLIVersion.fetch(tag: "master")
            checkedCLI = true
        }
    }
}
