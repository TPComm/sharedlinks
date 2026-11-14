import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the inbox cache and thumbnails live: the App Group container, unless a test binds
/// its own folder. Task-local, so parallel tests (and the tasks they start) stay apart.
enum CacheLocation {
    @TaskLocal static var testRoot: URL? = nil
    static var root: URL { testRoot ?? LinksConfig.sharedContainer }
}

/// The last inbox the app saw, written to the App Group so the widget can draw instantly
/// (and offline), and the app can launch with content before the first fetch finishes.
public enum InboxSnapshot {
    static var fileURL: URL { CacheLocation.root.appending(path: "inbox.json") }

    public static func load() -> InboxState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? APIClient.decoder.decode(InboxState.self, from: data)
    }

    public static func save(_ state: InboxState) {
        guard let data = try? APIClient.encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Apply a change to the cached inbox (e.g. when the widget marks something watched).
    public static func update(_ change: (inout InboxState) -> Void) {
        guard var state = load() else { return }
        change(&state)
        save(state)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        ThumbnailStore.clearDisk()
    }
}

/// Thumbnails come from the server (behind auth), are downsampled once, and are cached as small
/// JPEGs in the App Group so the widget can use them without a network round trip.
public actor ThumbnailStore {
    public static let shared = ThumbnailStore()
    /// Sharp enough for a full-width rich preview card on a 3x screen.
    public static let maxPixelSize = 800

    private var inFlight: [Int: Task<Data?, Never>] = [:]

    static var directory: URL {
        let dir = CacheLocation.root.appending(path: "thumbs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(_ id: Int) -> URL { directory.appending(path: "\(id).jpg") }

    public nonisolated static func cached(_ id: Int) -> Data? { try? Data(contentsOf: fileURL(id)) }

    /// Cached data if we have it, otherwise download, downsample and cache.
    public func data(for link: SharedLink, client: APIClient) async -> Data? {
        guard link.thumb != nil else { return nil }
        if let data = Self.cached(link.id) { return data }
        if let task = inFlight[link.id] { return await task.value }
        let task = Task<Data?, Never> {
            guard let raw = try? await client.thumbnail(link),
                  let small = Self.downsample(raw, maxPixelSize: Self.maxPixelSize) else { return nil }
            try? small.write(to: Self.fileURL(link.id), options: .atomic)
            return small
        }
        inFlight[link.id] = task
        let result = await task.value
        inFlight[link.id] = nil
        return result
    }

    /// Delete cached files for links that no longer exist.
    public nonisolated static func prune(keeping ids: Set<Int>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !ids.contains(Int(file.deletingPathExtension().lastPathComponent) ?? -1) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public nonisolated static func clearDisk() {
        try? FileManager.default.removeItem(at: directory)
    }

    public nonisolated static func downsample(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
