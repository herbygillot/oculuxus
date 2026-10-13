import Foundation
import Observation

/// The state of the ⌘K symbol search: the query, the helper's matches as
/// the user types, and which one is selected.
@Observable
@MainActor
final class SymbolSearchModel {
    enum Status: Equatable {
        case idle
        case searching
        /// The helper is still indexing the project; the message says how far.
        case indexing(String)
        /// Results cover the project, but not every dependency yet.
        case partial(indexed: Int, total: Int)
        case done
        case failed(String)
    }

    var query = "" {
        didSet { if query != oldValue { search(keepSelection: false) } }
    }
    var includeDependencies: Bool {
        didSet { if includeDependencies != oldValue { search(keepSelection: false) } }
    }
    private(set) var matches: [OcxSymbolMatch] = []
    var selection = 0
    private(set) var status: Status = .idle

    let session: ProjectSession
    /// How long to wait after a keystroke before searching.
    var debounce: Duration = .milliseconds(40)
    /// How often to search again while dependencies are being indexed.
    var refreshInterval: Duration = .milliseconds(500)

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(session: ProjectSession, includeDependencies: Bool) {
        self.session = session
        self.includeDependencies = includeDependencies
    }

    var selected: OcxSymbolMatch? {
        matches.indices.contains(selection) ? matches[selection] : nil
    }

    func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        selection = min(max(selection + delta, 0), matches.count - 1)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Searches for the current query, replacing any search in flight. While
    /// the index is incomplete it searches again every `refreshInterval`,
    /// keeping the selected match.
    func search(keepSelection: Bool) {
        task?.cancel()
        generation += 1
        let generation = generation
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            matches = []
            selection = 0
            status = .idle
            return
        }
        task = Task { [weak self, debounce, refreshInterval] in
            try? await Task.sleep(for: debounce)
            var keep = keepSelection
            while let self, !Task.isCancelled {
                if self.matches.isEmpty { self.status = .searching }
                do {
                    let response = try await self.session.search(query, includeDependencies: self.includeDependencies) { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.generation == generation else { return }
                            self.status = .indexing(message)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self.show(response.matches, keepSelection: keep)
                    if response.complete {
                        self.status = .done
                        return
                    }
                    self.status = .partial(indexed: Int(response.indexedPackages), total: Int(response.totalPackages))
                } catch is CancellationError {
                    return
                } catch {
                    self.status = .failed(error.localizedDescription)
                    return
                }
                keep = true
                try? await Task.sleep(for: refreshInterval)
            }
        }
    }

    private func show(_ new: [OcxSymbolMatch], keepSelection: Bool) {
        let previous = keepSelection ? selected.map(Self.key) : nil
        matches = new
        selection = previous.flatMap { key in new.firstIndex { Self.key($0) == key } } ?? 0
    }

    private static func key(_ m: OcxSymbolMatch) -> String {
        m.packageID + "#" + m.declarationID
    }

    /// Where a match leads: its declaration, or the package itself.
    static func location(of match: OcxSymbolMatch) -> WorkspaceLocation {
        WorkspaceLocation(packageID: match.packageID, declarationID: match.declarationID.isEmpty ? nil : match.declarationID)
    }
}
