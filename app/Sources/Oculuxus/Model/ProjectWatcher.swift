import CoreServices
import Foundation

/// Watches a project folder with FSEvents and reports the Go files and
/// module files that changed, in batches: a batch goes out once changes
/// pause for `quiet`, or after `maxDelay` while they keep coming (a
/// branch switch, a formatter run).
@MainActor
final class ProjectWatcher {
    let root: String
    private let quiet: Duration
    private let maxDelay: Duration
    private let onChange: @MainActor ([String]) -> Void

    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var firstPending: ContinuousClock.Instant?
    private var flush: Task<Void, Never>?

    init(root: String, quiet: Duration = .milliseconds(250), maxDelay: Duration = .seconds(1), onChange: @escaping @MainActor ([String]) -> Void) {
        self.root = Self.realPath(root)
        self.quiet = quiet
        self.maxDelay = maxDelay
        self.onChange = onChange
    }

    /// Starts watching. Returns false if FSEvents could not watch the folder.
    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: flags, count: count))
            MainActor.assumeIsolated { watcher.received(paths, flags: flags) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            return false
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    func stop() {
        flush?.cancel()
        flush = nil
        pending = []
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        guard stream != nil else { return }
        var added = false
        for (path, flag) in zip(paths, flags) {
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 {
                // Events were dropped: have the helper relist everything.
                pending.insert((root as NSString).appendingPathComponent("go.mod"))
                added = true
            } else if Self.isRelevant(path, root: root) {
                pending.insert(path)
                added = true
            }
        }
        guard added else { return }
        let now = ContinuousClock.now
        if firstPending == nil { firstPending = now }
        let wait = min(quiet, max(.zero, firstPending! + maxDelay - now))
        flush?.cancel()
        flush = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    private func deliver() {
        let paths = pending.sorted()
        pending = []
        firstPending = nil
        flush = nil
        if !paths.isEmpty { onChange(paths) }
    }

    /// Whether a change to `path` can affect the project: a .go file or a
    /// module file, outside the folders the go command ignores (names
    /// starting with "." or "_", and testdata).
    nonisolated static func isRelevant(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        let components = path.dropFirst(prefix.count).split(separator: "/")
        guard let name = components.last else { return false }
        for dir in components.dropLast() where dir.hasPrefix(".") || dir.hasPrefix("_") || dir == "testdata" {
            return false
        }
        if ["go.mod", "go.sum", "go.work", "go.work.sum"].contains(name) { return true }
        return name.hasSuffix(".go") && !name.hasPrefix(".") && !name.hasPrefix("_")
    }

    /// The path with symlinks resolved, as FSEvents reports paths
    /// (/var/... is /private/var/...).
    nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
