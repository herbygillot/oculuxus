import XCTest
@testable import Oculuxus

final class EditorTests: XCTestCase {
    private let target = EditorTarget(file: "/src/my proj/main.go", line: 42)

    /// A resolver over made-up tools and apps.
    private func resolver(tools: [String] = [], apps: [String: String] = [:], env: [String: String] = [:]) -> EditorResolver {
        EditorResolver(
            path: ["/opt/bin"],
            appURL: { id in apps[id].map { URL(fileURLWithPath: $0) } },
            isExecutable: { path in tools.contains(path) },
            environment: env
        )
    }

    func testPresetFromPath() {
        let r = resolver(tools: ["/opt/bin/code"])
        XCTAssertEqual(r.launch(.vscode, customCommand: "", target: target),
                       .run(executable: "/opt/bin/code", arguments: ["-g", "/src/my proj/main.go:42"]))
    }

    func testPresetFromAppBundle() {
        let zed = "/Applications/Zed.app"
        let r = resolver(tools: [zed + "/Contents/MacOS/cli"], apps: ["dev.zed.Zed": zed])
        XCTAssertEqual(r.launch(.zed, customCommand: "", target: target),
                       .run(executable: zed + "/Contents/MacOS/cli", arguments: ["/src/my proj/main.go:42"]))
    }

    func testGoLandWithoutLauncherUsesOpen() {
        let r = resolver(apps: ["com.jetbrains.goland": "/Applications/GoLand.app"])
        XCTAssertEqual(r.launch(.goland, customCommand: "", target: target),
                       .run(executable: "/usr/bin/open", arguments: ["-na", "/Applications/GoLand.app", "--args", "--line", "42", "/src/my proj/main.go"]))
    }

    func testMissingEditorFallsBackToDefaultApp() {
        XCTAssertEqual(resolver().launch(.sublime, customCommand: "", target: target), .defaultApp)
    }

    func testAutomaticPrefersEnvironment() {
        let r = resolver(tools: ["/opt/bin/code", "/opt/bin/subl"], env: ["EDITOR": "subl -w"])
        XCTAssertEqual(r.automaticEditor(), .sublime)
        // A terminal editor in $VISUAL is skipped for $EDITOR.
        let vim = resolver(tools: ["/opt/bin/code", "/opt/bin/zed"], env: ["VISUAL": "vim", "EDITOR": "/opt/bin/zed --wait"])
        XCTAssertEqual(vim.automaticEditor(), .zed)
    }

    func testAutomaticFallsBackToInstalledThenDefaultApp() {
        XCTAssertEqual(resolver(tools: ["/opt/bin/subl"], env: ["EDITOR": "vim"]).automaticEditor(), .sublime)
        XCTAssertNil(resolver().automaticEditor())
        XCTAssertEqual(resolver().launch(.automatic, customCommand: "", target: target), .defaultApp)
    }

    func testCustomCommandQuotesFile() {
        let r = resolver()
        XCTAssertEqual(r.launch(.custom, customCommand: "mate -l {line} {file}", target: target),
                       .shell("mate -l 42 '/src/my proj/main.go'"))
        let quote = EditorTarget(file: "/tmp/it's.go", line: 1)
        XCTAssertEqual(EditorResolver.expand("e {file}", target: quote), #"e '/tmp/it'\''s.go'"#)
        XCTAssertEqual(r.launch(.custom, customCommand: "  ", target: target), .defaultApp)
    }

    func testClickedLine() {
        let text = "// doc\nfunc F() {\n\treturn\n}"
        let first = EditorTarget(file: "/a.go", line: 10)
        XCTAssertEqual(SourceTextView.target(at: 0, in: text, firstLine: first).line, 10)
        XCTAssertEqual(SourceTextView.target(at: 8, in: text, firstLine: first).line, 11)
        XCTAssertEqual(SourceTextView.target(at: (text as NSString).length, in: text, firstLine: first).line, 13)
    }
}
