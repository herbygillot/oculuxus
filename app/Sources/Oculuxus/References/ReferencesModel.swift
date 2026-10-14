import Foundation
import Observation

extension OcxSymbolRef {
    init(packageID: String, declarationID: String = "") {
        self.init()
        self.packageID = packageID
        self.declarationID = declarationID
    }
}

/// What Find References and the call hierarchy are about: a declaration,
/// or the identifier at a position in a file (a local has no declaration).
struct ReferenceSubject: Equatable {
    var symbol: OcxSymbolRef?
    var position: OcxPosition?
    /// The package the position's file belongs to.
    var packageID = ""
    /// The identifier, shown until the hover card's signature arrives.
    var name: String
    var tests = false

    init(symbol: OcxSymbolRef, name: String, tests: Bool = false) {
        self.symbol = symbol
        self.name = name
        self.tests = tests
    }

    init(position: OcxPosition, packageID: String, name: String, tests: Bool = false) {
        self.position = position
        self.packageID = packageID
        self.name = name
        self.tests = tests
    }
}

enum ReferencesTab: Hashable {
    case references
    case callers
    case callees
}

/// The references panel at the bottom of a Workspace: the references to a
/// subject and, for a function or method, its callers and callees as trees
/// that expand one level at a time.
@Observable
@MainActor
final class ReferencesModel {
    enum Status: Equatable {
        case idle
        /// Waiting for the first results, with the helper's progress.
        case loading(String?)
        /// Results cover the project; the rest is still being type-checked.
        case partial(String)
        case done
        case failed(String)
    }

    let session: ProjectSession
    private(set) var subject: ReferenceSubject?
    var tab: ReferencesTab = .references {
        didSet { if tab != oldValue { loadTab() } }
    }
    /// Also look in dependencies and the standard library.
    var includeDependencies = false {
        didSet {
            guard includeDependencies != oldValue else { return }
            loadReferences(keepResults: true)
            callers?.cancel()
            callers = nil
            if tab == .callers { loadTab() }
        }
    }
    var isCollapsed = false
    var height: CGFloat = 240

    /// The subject's hover card, for the panel's header.
    private(set) var hover: OcxHover?
    /// The declaration the subject resolved to; nil for a local.
    private(set) var symbol: OcxSymbolRef?
    private(set) var resolved = false

    private(set) var references: [OcxReference] = []
    private(set) var groups: [ReferenceGroup] = []
    /// The number of references found, which exceeds `references.count`
    /// when the helper's limit cut the list.
    private(set) var total = 0
    private(set) var status: Status = .idle

    /// The subject as the root of the callers and the callees trees; the
    /// panel shows their children.
    private(set) var callers: CallNode?
    private(set) var callees: CallNode?

    /// The row last clicked, to keep it highlighted.
    var selectedRow: String?

    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var referencesTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(session: ProjectSession) {
        self.session = session
    }

    /// Functions and methods have callers and callees.
    var isCallable: Bool {
        symbol != nil && (hover?.kind == "func" || hover?.kind == "method")
    }

    /// Starts over with `subject`, on `tab`.
    func show(_ subject: ReferenceSubject, tab: ReferencesTab) {
        cancel()
        generation += 1
        self.subject = subject
        self.tab = tab
        isCollapsed = false
        hover = nil
        symbol = subject.symbol
        resolved = false
        references = []
        groups = []
        total = 0
        status = .idle
        selectedRow = nil
        callers = nil
        callees = nil
        let generation = generation
        resolveTask = Task { [weak self] in
            guard let self else { return }
            let hover: OcxHover?
            if let symbol = subject.symbol {
                hover = try? await self.session.hover(symbol, tests: subject.tests)
            } else if let position = subject.position {
                hover = try? await self.session.hover(at: position, packageID: subject.packageID, tests: subject.tests)
            } else {
                hover = nil
            }
            guard !Task.isCancelled, self.generation == generation else { return }
            self.hover = hover
            if self.symbol == nil, let hover, hover.hasTarget, !hover.target.declarationID.isEmpty {
                self.symbol = hover.target
            }
            self.resolved = true
            // The call hierarchy only applies to functions and methods.
            if self.tab != .references, !self.isCallable { self.tab = .references }
            self.loadTab()
        }
        loadReferences(keepResults: false)
    }

    func cancel() {
        resolveTask?.cancel()
        referencesTask?.cancel()
        callers?.cancel()
        callees?.cancel()
    }

    /// Asks again after the project changed on disk, keeping what is shown
    /// until the new results arrive.
    func refresh() {
        guard subject != nil else { return }
        loadReferences(keepResults: true)
        callers?.cancel()
        callees?.cancel()
        callers = nil
        callees = nil
        loadTab()
    }

    private func loadTab() {
        guard resolved, let symbol else { return }
        switch tab {
        case .references:
            break
        case .callers:
            if callers == nil { callers = root(symbol, .callers) }
        case .callees:
            if callees == nil { callees = root(symbol, .callees) }
        }
    }

    private func root(_ symbol: OcxSymbolRef, _ direction: OcxCallHierarchyRequest.Direction) -> CallNode {
        var item = OcxCallHierarchyItem()
        item.symbol = symbol
        // Callees come from the function's body, never from dependencies.
        let node = CallNode(item: item, direction: direction, session: session, includeDependencies: direction == .callers && includeDependencies)
        node.expand()
        return node
    }

    // MARK: References

    /// Asks for the project's references first, without waiting for
    /// dependencies, and shows them; then, when they are incomplete, asks
    /// again with `wait` for the rest, showing the helper's progress.
    private func loadReferences(keepResults: Bool) {
        guard let subject else { return }
        referencesTask?.cancel()
        var request = OcxReferencesRequest()
        if let symbol = subject.symbol {
            request.symbol = symbol
        } else if let position = subject.position {
            request.position = position
            request.packageID = subject.packageID
        }
        request.includeDependencies = includeDependencies
        if !keepResults || references.isEmpty { status = .loading(nil) }
        let generation = generation
        referencesTask = Task { [weak self] in
            guard let self else { return }
            let progress: HelperClient.ProgressHandler = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == generation, !(self.referencesTask?.isCancelled ?? true) else { return }
                    switch self.status {
                    case .partial: self.status = .partial(message)
                    default: self.status = .loading(message)
                    }
                }
            }
            do {
                var response = try await self.session.references(request, progress: progress)
                guard !Task.isCancelled else { return }
                self.apply(response)
                if !response.complete {
                    self.status = .partial(Self.progressText(response))
                    request.wait = true
                    response = try await self.session.references(request, progress: progress)
                    guard !Task.isCancelled else { return }
                    self.apply(response)
                }
                self.status = .done
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ response: OcxReferencesResponse) {
        references = response.references
        groups = ReferenceGroup.group(response.references)
        total = Int(response.total)
        if symbol == nil, response.hasSymbol, !response.symbol.declarationID.isEmpty { symbol = response.symbol }
    }

    nonisolated static func progressText(_ response: OcxReferencesResponse) -> String {
        "Type-checking \(response.indexedPackages) of \(response.totalPackages) packages"
    }

    /// "8 references in 3 files", with the shown count when the list was cut.
    var summary: String {
        let files = groups.reduce(0) { $0 + $1.files.count }
        let refs = total == 1 ? "1 reference" : "\(total) references"
        let inFiles = files == 1 ? "1 file" : "\(files) files"
        if total > references.count { return "\(refs), first \(references.count) shown" }
        return "\(refs) in \(inFiles)"
    }

    // MARK: Navigation

    /// Where a reference or call site is: its file and line, inside the
    /// declaration that contains it.
    nonisolated static func location(of ref: OcxReference) -> WorkspaceLocation {
        WorkspaceLocation(
            packageID: ref.packageID,
            declarationID: ref.enclosingID.isEmpty ? nil : ref.enclosingID,
            file: ref.location.file,
            line: Int(ref.location.line)
        )
    }

    /// Where a caller leads: the first call in it. A callee leads to its
    /// declaration, or to the call when it has none.
    nonisolated static func location(of item: OcxCallHierarchyItem, direction: OcxCallHierarchyRequest.Direction) -> WorkspaceLocation? {
        if direction == .callees, !item.symbol.declarationID.isEmpty {
            return WorkspaceLocation(packageID: item.symbol.packageID, declarationID: item.symbol.declarationID)
        }
        return item.sites.first.map(location(of:))
    }

    nonisolated static func rowID(_ ref: OcxReference) -> String {
        "\(ref.location.file):\(ref.location.line):\(ref.location.column)"
    }
}

/// References in one package, by file, in the helper's order.
struct ReferenceGroup: Identifiable, Equatable {
    var packageID: String
    var packageName: String
    var origin: OcxPackageOrigin
    var files: [FileGroup]

    var id: String { packageID }
    var count: Int { files.reduce(0) { $0 + $1.references.count } }

    struct FileGroup: Identifiable, Equatable {
        var file: String
        var references: [OcxReference]
        var id: String { file }
        var name: String { (file as NSString).lastPathComponent }
    }

    /// Groups consecutive references by package, then file, keeping the
    /// helper's order (the project's packages first).
    static func group(_ refs: [OcxReference]) -> [ReferenceGroup] {
        var groups: [ReferenceGroup] = []
        for ref in refs {
            if groups.last?.packageID != ref.packageID {
                groups.append(ReferenceGroup(packageID: ref.packageID, packageName: ref.packageName, origin: ref.origin, files: []))
            }
            if groups[groups.count - 1].files.last?.file != ref.location.file {
                groups[groups.count - 1].files.append(FileGroup(file: ref.location.file, references: []))
            }
            let last = groups[groups.count - 1].files.count - 1
            groups[groups.count - 1].files[last].references.append(ref)
        }
        return groups
    }
}

/// One caller or callee. Expanding it asks the helper for its own callers
/// or callees.
@Observable
@MainActor
final class CallNode: Identifiable {
    enum Children {
        case loading(String?)
        case loaded([CallNode])
        case failed(String)
    }

    let id = UUID()
    let item: OcxCallHierarchyItem
    let direction: OcxCallHierarchyRequest.Direction
    var isExpanded = false
    private(set) var children: Children?

    @ObservationIgnored private let session: ProjectSession
    @ObservationIgnored private let includeDependencies: Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    init(item: OcxCallHierarchyItem, direction: OcxCallHierarchyRequest.Direction, session: ProjectSession, includeDependencies: Bool) {
        self.item = item
        self.direction = direction
        self.session = session
        self.includeDependencies = includeDependencies
    }

    /// A function value or a call without a declaration has nothing to
    /// expand.
    var canExpand: Bool {
        !item.symbol.declarationID.isEmpty && item.callKind != .functionValue
    }

    /// The first call site, shown under the signature.
    var firstSite: OcxReference? { item.sites.first }

    func toggle() {
        if isExpanded {
            isExpanded = false
        } else {
            expand()
        }
    }

    func expand() {
        isExpanded = true
        switch children {
        case .loaded, .loading: return
        case .failed, nil: break
        }
        children = .loading(nil)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.session.callHierarchy(self.item.symbol, direction: self.direction, includeDependencies: self.includeDependencies) { [weak self] message in
                    Task { @MainActor in
                        guard let self, case .loading = self.children else { return }
                        self.children = .loading(message)
                    }
                }
                guard !Task.isCancelled else { return }
                self.children = .loaded(response.items.map {
                    CallNode(item: $0, direction: self.direction, session: self.session, includeDependencies: self.includeDependencies)
                })
            } catch is CancellationError {
                self.children = nil
                self.isExpanded = false
            } catch {
                self.children = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        if case let .loaded(nodes) = children { nodes.forEach { $0.cancel() } }
    }

    /// "via io.Reader" for a call through an interface, "function value"
    /// for a call of a variable, parameter, field or closure.
    var callLabel: String? {
        switch item.callKind {
        case .viaInterface: item.via.isEmpty ? "via interface" : "via \(item.via)"
        case .functionValue: "function value"
        default: nil
        }
    }
}
