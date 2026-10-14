import Foundation
import Observation

extension OcxPackage: Identifiable {}
extension OcxDeclaration: Identifiable {}

/// One open project: its helper process, the package list, and caches of
/// what views have asked for.
@Observable
@MainActor
final class ProjectSession {
    enum Status: Equatable {
        case opening(String)
        case ready
        /// The helper could not find a usable Go binary.
        case needsGoToolchain(String)
        case failed(String)
    }

    let rootDir: String
    private(set) var goBinary: String?
    /// The build tags and platform the project is loaded for.
    private(set) var target: BuildTarget
    private(set) var status: Status = .opening("Starting")
    private(set) var project: OcxProject?
    private(set) var listing = PackageListing()
    /// Bumped for a package each time files change under it; views showing
    /// the package load it again when its revision changes.
    private(set) var revisions: [String: Int] = [:]
    /// Bumped when the whole project is loaded again (for another target),
    /// which changes every package's revision.
    private(set) var generation = 0
    /// Bumped after every reload, so views showing results that span
    /// packages (references, callers) can ask again.
    private(set) var reloads = 0

    @ObservationIgnored private var client: HelperClient?
    @ObservationIgnored private var connecting: Task<HelperClient, Error>?
    @ObservationIgnored private let outlines = RequestCache<PackageKey, OcxPackageOutline>()
    @ObservationIgnored private let declarationSources = RequestCache<DeclarationKey, OcxDeclarationSourceResponse>()
    @ObservationIgnored private let fileSources = RequestCache<FileKey, OcxFileSourceResponse>()
    /// Hover cards by declaration.
    @ObservationIgnored private let hovers = RequestCache<DeclarationKey, OcxHover?>()
    @ObservationIgnored private var watcher: ProjectWatcher?
    /// Changed files waiting for the reload in progress to finish.
    @ObservationIgnored private var reloadQueue: [String] = []
    @ObservationIgnored private var reloading = false

    struct PackageKey: Hashable {
        var packageID: String
        var tests: Bool
    }

    struct DeclarationKey: Hashable {
        var packageID: String
        var declarationID: String
        var tests: Bool
    }

    struct FileKey: Hashable {
        var packageID: String
        var file: String
        var tests: Bool
    }

    init(rootDir: String, goBinary: String?, target: BuildTarget = BuildTarget()) {
        self.rootDir = rootDir
        self.goBinary = goBinary
        self.target = target
    }

    var name: String { (rootDir as NSString).lastPathComponent }

    /// Starts the helper, opens the project and lists its packages.
    /// `goBinary` replaces the one given at init when set.
    func open(goBinary: String? = nil) async {
        if let goBinary { self.goBinary = goBinary }
        status = .opening("Starting helper")
        project = nil
        listing = PackageListing()
        do {
            let client = try await connect()
            status = .opening("Listing packages")
            let response = try await client.listPackages { [weak self] message in
                Task { @MainActor in self?.progress(message) }
            }
            listing = PackageListing(response)
            status = .ready
            startWatching()
        } catch is CancellationError {
        } catch let error as HelperError where error.code == .goToolchain {
            status = .needsGoToolchain(error.localizedDescription)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Loads the project again for another target in a new helper: the
    /// package list, outlines, sources and symbol index all follow it.
    func reopen(target: BuildTarget) async {
        self.target = target
        outlines.invalidate { _ in true }
        declarationSources.invalidate { _ in true }
        fileSources.invalidate { _ in true }
        hovers.invalidate { _ in true }
        generation += 1
        await open()
    }

    private func progress(_ message: String) {
        if case .opening = status { status = .opening(message) }
    }

    /// A running helper with this project open. Starts a new helper, and
    /// reopens the project in it, when the previous one has exited.
    /// Concurrent callers share one start.
    private func connect() async throws -> HelperClient {
        if let client, client.isRunning, project != nil { return client }
        if let connecting { return try await connecting.value }
        let task = Task { try await startHelper() }
        connecting = task
        defer { connecting = nil }
        return try await task.value
    }

    private func startHelper() async throws -> HelperClient {
        guard let helper = HelperEnvironment.helperURL() else {
            throw HelperError.launchFailed("oculuxus-helper was not found. Run `make build` at the repository root, or set OCULUXUS_HELPER.")
        }
        // Finding the login shell's PATH runs a shell; keep it off the main actor.
        let (environment, located) = await Task.detached {
            (HelperEnvironment.environment(), GoToolchain.locate())
        }.value
        let previous = client
        Task.detached { previous?.shutdown(timeout: 0.2) }
        let client = try HelperClient(executable: helper, environment: environment)
        self.client = client
        project = nil

        var request = OcxOpenProjectRequest()
        request.rootDir = rootDir
        request.goBinary = goBinary ?? located ?? ""
        request.buildTags = target.tags
        request.goos = target.goos
        request.goarch = target.goarch
        project = try await client.openProject(request) { [weak self] message in
            Task { @MainActor in self?.progress(message) }
        }
        return client
    }

    /// Stops the helper and the folder watcher. The session can be opened
    /// again later.
    func close() {
        watcher?.stop()
        watcher = nil
        let client = self.client
        self.client = nil
        Task.detached { client?.shutdown() }
    }

    // MARK: Live reload

    private func startWatching() {
        guard watcher == nil else { return }
        let watcher = ProjectWatcher(root: rootDir) { [weak self] files in
            Task { await self?.reload(files) }
        }
        if watcher.start() { self.watcher = watcher }
    }

    func revision(of packageID: String) -> Int {
        (revisions[packageID] ?? 0) + generation
    }

    /// Tells the helper which files changed, drops what is cached for the
    /// packages it reports, relists packages when the list changed, and
    /// bumps those packages' revisions so open Workspaces refresh. Batches
    /// that arrive during a reload are sent together after it.
    func reload(_ files: [String]) async {
        reloadQueue.append(contentsOf: files)
        guard !reloading else { return }
        reloading = true
        defer { reloading = false }
        while !reloadQueue.isEmpty {
            let batch = Array(Set(reloadQueue)).sorted()
            reloadQueue = []
            guard status == .ready, let client, client.isRunning else { return }
            do {
                let response = try await client.reload(changedFiles: batch)
                var changed = Set(response.changedPackageIds)
                if response.packageListChanged {
                    listing = PackageListing(try await client.listPackages())
                    // The helper dropped every type-checked package.
                    changed.formUnion(outlines.keys.map(\.packageID))
                    outlines.invalidate { _ in true }
                    declarationSources.invalidate { _ in true }
                    fileSources.invalidate { _ in true }
                    hovers.invalidate { _ in true }
                } else {
                    outlines.invalidate { changed.contains($0.packageID) }
                    declarationSources.invalidate { changed.contains($0.packageID) }
                    fileSources.invalidate { changed.contains($0.packageID) }
                    hovers.invalidate { changed.contains($0.packageID) }
                }
                for id in changed { revisions[id, default: 0] += 1 }
                reloads += 1
            } catch {
                // The helper stopped; the next request restarts it.
                return
            }
        }
    }

    // MARK: Lookups

    func package(_ id: String) -> OcxPackage? {
        listing.byID[id]
    }

    /// Whether requests for the package include test files: when the user
    /// shows tests, and always for an external test package ("pkg_test"),
    /// which only exists with them.
    func includesTests(_ packageID: String, showsTests: Bool) -> Bool {
        showsTests || (package(packageID) == nil && packageID.hasSuffix("_test"))
    }

    /// The package's outline; with `tests`, including its _test.go files.
    func outline(_ packageID: String, tests: Bool = false) async throws -> OcxPackageOutline {
        try await outlines.value(for: PackageKey(packageID: packageID, tests: tests)) { [self] in
            try await connect().packageOutline(packageID, includeTests: tests)
        }
    }

    func declarationSource(_ location: WorkspaceLocation, tests: Bool = false) async throws -> OcxDeclarationSourceResponse {
        let key = DeclarationKey(packageID: location.packageID, declarationID: location.declarationID ?? "", tests: tests)
        return try await declarationSources.value(for: key) { [self] in
            try await connect().declarationSource(packageID: key.packageID, declarationID: key.declarationID, includeTests: tests)
        }
    }

    func fileSource(packageID: String, file: String, tests: Bool = false) async throws -> OcxFileSourceResponse {
        try await fileSources.value(for: FileKey(packageID: packageID, file: file, tests: tests)) { [self] in
            try await connect().fileSource(packageID: packageID, file: file, includeTests: tests)
        }
    }

    /// Searches the symbol index. Results cover the project once it is
    /// indexed; `complete` in the response says whether dependencies are
    /// fully indexed yet.
    func search(_ query: String, includeDependencies: Bool, limit: Int = 80, progress: HelperClient.ProgressHandler? = nil) async throws -> OcxSearchResponse {
        var request = OcxSearchRequest()
        request.query = query
        request.includeDependencies = includeDependencies
        request.limit = UInt32(limit)
        return try await connect().search(request, progress: progress)
    }

    /// Every use of a declaration, or of the identifier at a position.
    /// Without `wait` the results cover the project once it is indexed;
    /// with it, everything in scope.
    func references(_ request: OcxReferencesRequest, progress: HelperClient.ProgressHandler? = nil) async throws -> OcxReferencesResponse {
        try await connect().references(request, progress: progress)
    }

    /// One level of callers or callees of a function or method.
    func callHierarchy(_ symbol: OcxSymbolRef, direction: OcxCallHierarchyRequest.Direction, includeDependencies: Bool, wait: Bool = true, progress: HelperClient.ProgressHandler? = nil) async throws -> OcxCallHierarchyResponse {
        var request = OcxCallHierarchyRequest()
        request.symbol = symbol
        request.direction = direction
        request.includeDependencies = includeDependencies
        request.wait = wait
        return try await connect().callHierarchy(request, progress: progress)
    }

    /// The hover card for a declaration, cached until its package changes.
    func hover(_ symbol: OcxSymbolRef, tests: Bool = false) async throws -> OcxHover? {
        let key = DeclarationKey(packageID: symbol.packageID, declarationID: symbol.declarationID, tests: tests)
        return try await hovers.value(for: key) { [self] in
            var request = OcxHoverRequest()
            request.symbol = symbol
            request.includeTests = tests
            return try await connect().hover(request)
        }
    }

    /// The hover card for the identifier at a byte offset in a file of
    /// `packageID`. Not cached: positions are only asked for identifiers
    /// without a declaration to navigate to, such as locals.
    func hover(at position: OcxPosition, packageID: String, tests: Bool = false) async throws -> OcxHover? {
        var request = OcxHoverRequest()
        request.position = position
        request.packageID = packageID
        request.includeTests = tests
        return try await connect().hover(request)
    }
}

/// The package list grouped the way the Navigator shows it.
struct PackageListing {
    var packages: [OcxPackage] = []
    var byID: [String: OcxPackage] = [:]
    var projectPackages: [OcxPackage] = []
    var stdlibPackages: [OcxPackage] = []
    /// Dependency modules, each with its packages.
    var dependencies: [ModuleGroup] = []

    struct ModuleGroup: Identifiable {
        var module: OcxModule
        var packages: [OcxPackage]
        var id: String { module.path + "@" + module.version }
    }

    init() {}

    init(_ response: OcxListPackagesResponse) {
        let sorted = response.packages.sorted { $0.importPath < $1.importPath }
        packages = sorted
        byID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        projectPackages = sorted.filter { $0.origin == .project }
        stdlibPackages = sorted.filter { $0.origin == .stdlib }
        let byModule = Dictionary(grouping: sorted.filter { $0.origin == .dependency }) { ModuleKey(path: $0.modulePath, version: $0.moduleVersion) }
        dependencies = response.modules
            .filter { !$0.main }
            .sorted { ($0.path, $0.version) < ($1.path, $1.version) }
            .compactMap { module in
                guard let packages = byModule[ModuleKey(path: module.path, version: module.version)] else { return nil }
                return ModuleGroup(module: module, packages: packages)
            }
    }

    private struct ModuleKey: Hashable {
        var path: String
        var version: String
    }
}

/// Deduplicates and caches requests. Callers asking for the same key share
/// one request; when every caller waiting on it is cancelled, the request
/// is cancelled too (which sends the helper a Cancel). Failures are not
/// cached.
@MainActor
final class RequestCache<Key: Hashable, Value: Sendable> {
    @MainActor private final class Entry {
        var task: Task<Value, Error>?
        var waiters = 0
        /// Invalidated while in flight: the value must not be cached.
        var stale = false
    }

    @MainActor private final class Waiter {
        var released = false
    }

    private var values: [Key: Value] = [:]
    private var inflight: [Key: Entry] = [:]

    func cached(_ key: Key) -> Value? { values[key] }

    var keys: Set<Key> { Set(values.keys).union(inflight.keys) }

    /// Forgets the values for matching keys. Requests in flight for them
    /// still answer their waiters but are not cached; the next caller
    /// starts a new request.
    func invalidate(where matches: (Key) -> Bool) {
        for key in values.keys where matches(key) { values[key] = nil }
        for (key, entry) in inflight where matches(key) {
            entry.stale = true
            inflight[key] = nil
        }
    }

    func value(for key: Key, load: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let value = values[key] { return value }
        let entry: Entry
        if let existing = inflight[key] {
            entry = existing
        } else {
            entry = Entry()
            inflight[key] = entry
            entry.task = Task { @MainActor [weak self] in
                defer { if self?.inflight[key] === entry { self?.inflight[key] = nil } }
                let value = try await load()
                if !entry.stale { self?.values[key] = value }
                return value
            }
        }
        entry.waiters += 1
        let task = entry.task!
        let waiter = Waiter()
        return try await withTaskCancellationHandler {
            defer { release(key, entry, waiter, cancelling: false) }
            return try await task.value
        } onCancel: {
            Task { @MainActor in self.release(key, entry, waiter, cancelling: true) }
        }
    }

    private func release(_ key: Key, _ entry: Entry, _ waiter: Waiter, cancelling: Bool) {
        guard !waiter.released else { return }
        waiter.released = true
        entry.waiters -= 1
        if cancelling, entry.waiters == 0, inflight[key] === entry {
            inflight[key] = nil
            entry.task?.cancel()
        }
    }
}
