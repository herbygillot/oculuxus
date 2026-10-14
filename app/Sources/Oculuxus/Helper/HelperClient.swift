import Foundation
import os
import SwiftProtobuf

/// An error from the helper or from talking to it.
enum HelperError: LocalizedError, Equatable {
    /// The helper answered with an Error response.
    case helper(OcxError.Code, String)
    /// The helper process could not be started.
    case launchFailed(String)
    /// The helper process exited. Carries the end of its stderr.
    case exited(String)
    /// The helper answered with a response of the wrong type.
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case let .helper(_, message): message
        case let .launchFailed(message): "Could not start the helper: \(message)"
        case let .exited(stderr): stderr.isEmpty ? "The helper stopped." : "The helper stopped: \(stderr)"
        case .unexpectedResponse: "The helper sent an unexpected response."
        }
    }

    var code: OcxError.Code? {
        if case let .helper(code, _) = self { return code }
        return nil
    }
}

/// Runs the Go helper as a child process and speaks the protocol in
/// proto/oculuxus/v1/oculuxus.proto over its stdin and stdout: varint
/// length-prefixed messages (BinaryDelimited), many requests in flight at
/// once, Progress responses before each final one.
///
/// Cancelling the Swift task that awaits a request sends the helper a
/// Cancel for it, so views that stop caring about a result (the user
/// clicked elsewhere) stop the work too.
final class HelperClient: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (String) -> Void

    private struct Pending {
        var continuation: CheckedContinuation<OcxResponse.OneOf_Body, Error>
        var progress: ProgressHandler?
    }

    private struct State {
        var nextID: UInt64 = 1
        var pending: [UInt64: Pending] = [:]
        /// Requests whose task was cancelled before they were written.
        var cancelledEarly: Set<UInt64> = []
        var exited: HelperError?
        /// The end of the helper's stderr, for error messages.
        var stderrTail = ""
    }

    private let process = Process()
    private let stdin: FileHandle
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Serializes writes so frames never interleave.
    private let writeLock = NSLock()

    /// Every client that is running, so the app can shut them down on quit.
    private static let running = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: HelperClient]())

    /// Launches the helper at `executable`. `environment` is the child's
    /// whole environment.
    init(executable: URL, environment: [String: String]) throws {
        // A write after the helper exits must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        stdin = input.fileHandleForWriting

        errors.fileHandleForReading.readabilityHandler = { [state] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            FileHandle.standardError.write(data)
            state.withLock {
                $0.stderrTail = String((($0.stderrTail) + String(decoding: data, as: UTF8.self)).suffix(2000))
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        do {
            try process.run()
        } catch {
            throw HelperError.launchFailed(error.localizedDescription)
        }
        Self.running.withLock { $0[ObjectIdentifier(self)] = self }

        let readFD = output.fileHandleForReading.fileDescriptor
        let thread = Thread { [weak self] in
            Self.readResponses(fd: readFD, to: self)
        }
        thread.name = "oculuxus-helper reader"
        thread.start()
        // The child has its own copies now.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }

    var isRunning: Bool {
        state.withLock { $0.exited == nil }
    }

    // MARK: Requests

    /// Sends a request and returns the final response's body. An Error
    /// response is thrown as `HelperError.helper`, and CANCELLED as
    /// `CancellationError`.
    func request(_ body: OcxRequest.OneOf_Body, progress: ProgressHandler? = nil) async throws -> OcxResponse.OneOf_Body {
        let id = state.withLock { s -> UInt64 in
            defer { s.nextID += 1 }
            return s.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let failure = state.withLock { s -> Error? in
                    if s.cancelledEarly.remove(id) != nil { return CancellationError() }
                    if let exited = s.exited { return exited }
                    s.pending[id] = Pending(continuation: continuation, progress: progress)
                    return nil
                }
                if let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                var request = OcxRequest()
                request.id = id
                request.body = body
                if let error = write(request) {
                    resolve(id, with: .failure(error))
                }
            }
        } onCancel: {
            let started = state.withLock { s -> Bool in
                if s.pending[id] != nil { return true }
                // Either not written yet, or already answered; in the latter
                // case the id is simply never used again.
                s.cancelledEarly.insert(id)
                return false
            }
            if started { sendCancel(id) }
        }
    }

    private func sendCancel(_ requestID: UInt64) {
        var cancel = OcxCancel()
        cancel.requestID = requestID
        var request = OcxRequest()
        request.id = state.withLock { s -> UInt64 in
            defer { s.nextID += 1 }
            return s.nextID
        }
        request.body = .cancel(cancel)
        // The Empty answer has no waiter and is dropped.
        _ = write(request)
    }

    private func write(_ request: OcxRequest) -> HelperError? {
        let stream = OutputStream.toMemory()
        stream.open()
        defer { stream.close() }
        do {
            try BinaryDelimited.serialize(message: request, to: stream)
        } catch {
            return .launchFailed("encoding request: \(error)")
        }
        guard let data = stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data else {
            return .unexpectedResponse
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try stdin.write(contentsOf: data)
            return nil
        } catch {
            return .exited(state.withLock { $0.stderrTail })
        }
    }

    // MARK: Responses

    /// Runs on the reader thread until the helper's stdout closes.
    private static func readResponses(fd: Int32, to client: HelperClient?) {
        guard let stream = InputStream(fileAtPath: "/dev/fd/\(fd)") else {
            client?.finish()
            return
        }
        stream.open()
        defer { stream.close() }
        while true {
            let response: OcxResponse
            do {
                response = try BinaryDelimited.parse(messageType: OcxResponse.self, from: stream)
            } catch {
                break
            }
            guard let client else { return }
            client.handle(response)
        }
        client?.finish()
    }

    private func handle(_ response: OcxResponse) {
        switch response.body {
        case let .progress(progress):
            let handler = state.withLock { $0.pending[response.id]?.progress }
            handler?(progress.message)
        case let .error(error) where error.code == .cancelled:
            resolve(response.id, with: .failure(CancellationError()))
        case let .error(error):
            resolve(response.id, with: .failure(HelperError.helper(error.code, error.message)))
        case let body?:
            resolve(response.id, with: .success(body))
        case nil:
            resolve(response.id, with: .failure(HelperError.unexpectedResponse))
        }
    }

    private func resolve(_ id: UInt64, with result: Result<OcxResponse.OneOf_Body, Error>) {
        let pending = state.withLock { $0.pending.removeValue(forKey: id) }
        pending?.continuation.resume(with: result)
    }

    /// Fails every waiting request once the helper is gone.
    private func finish() {
        let pending = state.withLock { s -> [Pending] in
            if s.exited == nil { s.exited = .exited(s.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)) }
            defer { s.pending.removeAll() }
            return Array(s.pending.values)
        }
        let error = state.withLock { $0.exited! }
        for p in pending { p.continuation.resume(throwing: error) }
        Self.running.withLock { $0[ObjectIdentifier(self)] = nil }
    }

    // MARK: Shutdown

    /// Asks the helper to exit, waiting up to `timeout` before killing it.
    /// Blocks the calling thread; meant for app quit and project switches.
    func shutdown(timeout: TimeInterval = 1) {
        guard process.isRunning else { return }
        var request = OcxRequest()
        request.id = state.withLock { s -> UInt64 in
            defer { s.nextID += 1 }
            return s.nextID
        }
        request.body = .shutdown(OcxShutdown())
        _ = write(request)
        try? stdin.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate() }
    }

    /// Shuts down every running helper. Called when the app quits.
    static func shutdownAll() {
        let clients = running.withLock { Array($0.values) }
        for client in clients { client.shutdown() }
    }
}

extension HelperClient {
    func openProject(_ request: OcxOpenProjectRequest, progress: ProgressHandler? = nil) async throws -> OcxProject {
        guard case let .openProject(r) = try await self.request(.openProject(request), progress: progress) else { throw HelperError.unexpectedResponse }
        return r.project
    }

    func listPackages(progress: ProgressHandler? = nil) async throws -> OcxListPackagesResponse {
        guard case let .listPackages(r) = try await request(.listPackages(OcxListPackagesRequest()), progress: progress) else { throw HelperError.unexpectedResponse }
        return r
    }

    func packageOutline(_ packageID: String, includeTests: Bool = false, progress: ProgressHandler? = nil) async throws -> OcxPackageOutline {
        var req = OcxPackageOutlineRequest()
        req.packageID = packageID
        req.includeTests = includeTests
        guard case let .packageOutline(r) = try await request(.packageOutline(req), progress: progress) else { throw HelperError.unexpectedResponse }
        return r.outline
    }

    func declarationSource(packageID: String, declarationID: String, includeTests: Bool = false) async throws -> OcxDeclarationSourceResponse {
        var req = OcxDeclarationSourceRequest()
        req.packageID = packageID
        req.declarationID = declarationID
        req.includeTests = includeTests
        guard case let .declarationSource(r) = try await request(.declarationSource(req)) else { throw HelperError.unexpectedResponse }
        return r
    }

    func fileSource(packageID: String, file: String, includeTests: Bool = false) async throws -> OcxFileSourceResponse {
        var req = OcxFileSourceRequest()
        req.packageID = packageID
        req.file = file
        req.includeTests = includeTests
        guard case let .fileSource(r) = try await request(.fileSource(req)) else { throw HelperError.unexpectedResponse }
        return r
    }

    func reload(changedFiles: [String]) async throws -> OcxReloadResponse {
        var req = OcxReloadRequest()
        req.changedFiles = changedFiles
        guard case let .reload(r) = try await request(.reload(req)) else { throw HelperError.unexpectedResponse }
        return r
    }

    func search(_ req: OcxSearchRequest, progress: ProgressHandler? = nil) async throws -> OcxSearchResponse {
        guard case let .search(r) = try await request(.search(req), progress: progress) else { throw HelperError.unexpectedResponse }
        return r
    }

    func references(_ req: OcxReferencesRequest, progress: ProgressHandler? = nil) async throws -> OcxReferencesResponse {
        guard case let .references(r) = try await request(.references(req), progress: progress) else { throw HelperError.unexpectedResponse }
        return r
    }

    func callHierarchy(_ req: OcxCallHierarchyRequest, progress: ProgressHandler? = nil) async throws -> OcxCallHierarchyResponse {
        guard case let .callHierarchy(r) = try await request(.callHierarchy(req), progress: progress) else { throw HelperError.unexpectedResponse }
        return r
    }

    /// The hover card for a declaration or a position; nil when there is
    /// nothing to describe.
    func hover(_ req: OcxHoverRequest) async throws -> OcxHover? {
        guard case let .hover(r) = try await request(.hover(req)) else { throw HelperError.unexpectedResponse }
        return r.hasHover ? r.hover : nil
    }
}
