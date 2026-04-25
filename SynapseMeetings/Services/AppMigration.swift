import Foundation
import Security

/// One-time data migrations that run before AppState is constructed.
///
/// Synapse Meetings was previously shipped under the bundle id `com.voxcommit.app`
/// and the display name "VoxCommit". When users upgrade we want to carry over their
/// Keychain secrets and on-disk recordings so nothing appears to be lost.
enum AppMigration {
    private static let didRunKey = "synapse.migration.didRunV1"
    private static let oldKeychainService = "com.voxcommit.app"
    private static let oldAppSupportFolderName = "VoxCommit"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didRunKey) else { return }

        migrateKeychainItems()
        migrateApplicationSupportFolder()

        defaults.set(true, forKey: didRunKey)
    }

    // MARK: - Keychain

    /// Copies any items stored under the old service id into the new one,
    /// without deleting the originals (so a user could roll back if needed).
    private static func migrateKeychainItems() {
        for key in KeychainKey.allCases {
            guard let value = readOldKeychainItem(account: key.rawValue),
                  KeychainService.shared.get(key) == nil else { continue }
            try? KeychainService.shared.set(value, for: key)
        }
    }

    private static func readOldKeychainItem(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldKeychainService,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    // MARK: - Application Support

    /// Moves the previous `~/Library/Application Support/VoxCommit` directory
    /// to the new app folder so historical recordings remain accessible.
    private static func migrateApplicationSupportFolder() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }

        let oldDir = appSupport.appendingPathComponent(oldAppSupportFolderName, isDirectory: true)
        let newDir = appSupport.appendingPathComponent(RecordingStore.appSupportFolderName, isDirectory: true)

        guard fm.fileExists(atPath: oldDir.path) else { return }

        // If the new directory doesn't exist, a simple move is cheapest.
        if !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
            return
        }

        // Both exist: merge by copying any files the new dir doesn't already have,
        // then leave the old dir alone for safety.
        mergeContents(from: oldDir, into: newDir, fileManager: fm)
    }

    private static func mergeContents(from source: URL, into destination: URL, fileManager fm: FileManager) {
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: source.path, with: "")
            let target = destination.appendingPathComponent(relative)
            if fm.fileExists(atPath: target.path) { continue }
            try? fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fm.copyItem(at: url, to: target)
        }
    }
}
