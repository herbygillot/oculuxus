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
    private(set) var status: Status = .opening("Starting")
    private(set) var project: OcxProject?
    private(set) var listing = PackageListing()

    @ObservationIgnored private var client: HelperClient?
    @ObservationIgnored private var connecting: Task<HelperClient, Error>?
    @ObservationIgnored private let outlines = RequestCache<String, OcxPackageOutline>()
    @ObservationIgnored private let declarationSources = RequestCache<WorkspaceLocation, OcxDeclarationSourceResponse>()
    @ObservationIgnored private let fileSources = RequestCache<String, OcxFileSourceResponse>()

    init(rootDir: String, goBinary: String?) {
        self.rootDir = rootDir
        self.goBinary = goBinary
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
        } catch is CancellationError {
        } catch let error as HelperError where error.code == .goToolchain {
            status = .needsGoToolchain(error.localizedDescription)
        } catch {
            status = .failed(error.localizedDescription)
        }
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
        project = try await client.openProject(request) { [weak self] message in
            Task { @MainActor in self?.progress(message) }
        }
        return client
    }

    /// Stops the helper. The session can be opened again later.
    func close() {
        let client = self.client
        self.client = nil
        Task.detached { client?.shutdown() }
    }

    // MARK: Lookups

    func package(_ id: String) -> OcxPackage? {
        listing.byID[id]
    }

    func outline(_ packageID: String) async throws -> OcxPackageOutline {
        try await outlines.value(for: packageID) { [self] in
            try await connect().packageOutline(packageID)
        }
    }

    func declarationSource(_ location: WorkspaceLocation) async throws -> OcxDeclarationSourceResponse {
        try await declarationSources.value(for: location) { [self] in
            try await connect().declarationSource(packageID: location.packageID, declarationID: location.declarationID ?? "")
        }
    }

    func fileSource(packageID: String, file: String) async throws -> OcxFileSourceResponse {
        try await fileSources.value(for: file) { [self] in
            try await connect().fileSource(packageID: packageID, file: file)
        }
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
    }

    @MainActor private final class Waiter {
        var released = false
    }

    private var values: [Key: Value] = [:]
    private var inflight: [Key: Entry] = [:]

    func cached(_ key: Key) -> Value? { values[key] }

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
                self?.values[key] = value
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
