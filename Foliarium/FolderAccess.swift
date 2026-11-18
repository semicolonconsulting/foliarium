import Foundation

/// Which edition this is. The App Store edition runs in the App Sandbox, which can't read the Trash, so it has
/// no "Delete files in Trash" action. The Developer ID edition (the DMG) has everything.
enum Edition {
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    static var canEmptyTrash: Bool { !isSandboxed }
}

/// In the App Sandbox, Foliarium may only use folders the user chose in an Open panel. It keeps a
/// security-scoped bookmark for each one, so the permission lasts across launches, and keeps using them
/// while it runs. Outside the sandbox every folder is allowed and this does nothing.
enum FolderAccess {
    private static let defaultsKey = "FolderBookmarks"
    private static let lock = NSLock()
    /// The folders in use, by path.
    private static var granted: [String: URL] = [:]

    /// Starts using every folder chosen before. Call once at launch, before the rules run.
    static func restore() {
        guard Edition.isSandboxed else { return }
        let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
        var kept: [String: Data] = [:]
        lock.lock()
        for (path, data) in saved {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else {
                NSLog("Foliarium: lost access to \(path)")
                continue
            }
            granted[url.path] = url
            kept[url.path] = stale ? (bookmark(for: url) ?? data) : data
        }
        lock.unlock()
        UserDefaults.standard.set(kept, forKey: defaultsKey)
    }

    /// Remembers a folder the user just chose in an Open panel, and starts using it.
    static func remember(_ url: URL) {
        guard Edition.isSandboxed, let data = bookmark(for: url) else { return }
        lock.lock()
        if granted[url.path] == nil, url.startAccessingSecurityScopedResource() { granted[url.path] = url }
        lock.unlock()
        var saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
        saved[url.path] = data
        UserDefaults.standard.set(saved, forKey: defaultsKey)
    }

    /// Whether Foliarium may use `path`: always outside the sandbox, and inside it when the path is in a
    /// folder the user chose.
    static func canUse(_ path: String) -> Bool {
        guard Edition.isSandboxed else { return true }
        guard !path.isEmpty else { return false }
        let expanded = Paths.expand(path)
        let resolved = Paths.canonical(expanded)
        lock.lock()
        defer { lock.unlock() }
        return granted.keys.contains { folder in
            Paths.isInside(expanded, folder) || resolved.map { Paths.isInside($0, Paths.canonical(folder) ?? folder) } == true
        }
    }

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
