import AppKit
import Observation

/// Looks for a newer app release on GitHub. The app has no auto-update, so this is how players hear about fixes.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", draft, prerelease
        }

        /// "1.2.0" for a tag like "v1.2.0"; nil for other tags such as "data-v1".
        var version: String? {
            let v = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            return v.wholeMatch(of: /\d+(\.\d+)*/) != nil ? v : nil
        }
    }

    static let shared = UpdateChecker()

    var checksOnLaunch: Bool {
        didSet { UserDefaults.standard.set(checksOnLaunch, forKey: "checkForUpdates") }
    }

    /// Set when a release newer than this app was found.
    private(set) var available: Release?

    private init() {
        checksOnLaunch = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The highest app release newer than `current`, skipping drafts, prereleases and data tags.
    nonisolated static func newest(in releases: [Release], newerThan current: String) -> Release? {
        releases
            .filter { !$0.draft && !$0.prerelease && $0.version != nil }
            .max { $0.version!.compare($1.version!, options: .numeric) == .orderedAscending }
            .flatMap { $0.version!.compare(current, options: .numeric) == .orderedDescending ? $0 : nil }
    }

    func checkOnLaunch() {
        guard checksOnLaunch else { return }
        Task { try? await check() }
    }

    /// Checks now and tells the player the outcome, for the menu item and the Settings button.
    func checkNow() {
        Task {
            let alert = NSAlert()
            do {
                if let release = try await check() {
                    alert.messageText = "Populus \(release.version ?? "") is available"
                    alert.informativeText = "You have \(Self.currentVersion)."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
                    return
                }
                alert.messageText = "You're up to date"
                alert.informativeText = "Populus \(Self.currentVersion) is the latest version."
            } catch {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
    }

    @discardableResult
    private func check() async throws -> Release? {
        var request = URLRequest(url: Links.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let releases = try JSONDecoder().decode([Release].self, from: data)
        available = Self.newest(in: releases, newerThan: Self.currentVersion)
        return available
    }
}
