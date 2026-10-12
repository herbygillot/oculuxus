import Foundation
import os

/// Finds the helper binary and the Go toolchain, and builds the
/// environment the helper runs in.
enum HelperEnvironment {
    /// The helper binary: $OCULUXUS_HELPER, then one bundled with the app,
    /// then `bin/oculuxus-helper` in the repository this app was built
    /// from (`make build` at the repository root puts it there).
    static func helperURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["OCULUXUS_HELPER"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let url = Bundle.main.url(forAuxiliaryExecutable: "oculuxus-helper") {
            candidates.append(url)
        }
        candidates.append(repositoryRoot.appending(path: "bin/oculuxus-helper"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// The repository root, from this source file's location:
    /// app/Sources/Oculuxus/Helper/HelperEnvironment.swift.
    static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    /// The helper's environment: ours, with PATH extended by the login
    /// shell's PATH and the usual Go install locations. Apps launched from
    /// Finder get a minimal PATH, so the helper (and the `go` it runs)
    /// would otherwise miss tools the user's shell can see.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = unique(GoToolchain.loginShellPath() + current + GoToolchain.commonDirectories()).joined(separator: ":")
        return env
    }

    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Locates a Go binary for the helper when the user has not picked one.
enum GoToolchain {
    /// Directories where Go is commonly installed, most specific first.
    static func commonDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/usr/local/go/bin", "/opt/homebrew/bin", "/opt/local/bin", "/usr/local/bin", home + "/go/bin"]
        // ~/sdk/go1.27.1/bin and friends, as installed by golang.org/dl, newest first.
        let sdk = home + "/sdk"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: sdk) {
            let versions = names.filter { $0.hasPrefix("go") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            dirs += versions.map { "\(sdk)/\($0)/bin" }
        }
        return dirs
    }

    /// The first `go` on the login shell's PATH or in a common location.
    static func locate() -> String? {
        let dirs = HelperEnvironment.unique(loginShellPath() + commonDirectories())
        return dirs.map { $0 + "/go" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Where a Go binary picker should start.
    static var pickerDirectory: URL {
        let dir = commonDirectories().first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/local"
        return URL(fileURLWithPath: dir)
    }

    private static let shellPath = OSAllocatedUnfairLock<[String]?>(initialState: nil)

    /// PATH as the user's interactive login shell sets it. Computed once.
    static func loginShellPath() -> [String] {
        if let path = shellPath.withLock({ $0 }) { return path }
        let path = readLoginShellPath()
        shellPath.withLock { $0 = path }
        return path
    }

    private static func readLoginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__OCULUXUS_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive so PATH set in .zshrc or .bashrc counts too; the
        // markers skip anything the rc files print.
        process.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return [] }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return []
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return [] }
        return parts[1].split(separator: ":").map(String.init)
    }
}
