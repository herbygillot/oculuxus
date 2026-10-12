# Oculuxus app

The macOS app: native SwiftUI, macOS 14 or later. It is a Swift package,
so there is no checked-in Xcode project; open `app/Package.swift` in Xcode,
or build from the command line:

```sh
swift build          # or: xcodebuild -scheme Oculuxus -destination platform=macOS build
swift test
swift run Oculuxus
```

The app runs the Go helper as a child process. For development it uses
`bin/oculuxus-helper` in this repository, so build that first with `make build`
at the repository root (or point `OCULUXUS_HELPER` at a helper binary). Open a
project with Open Folder… (⌘O), or pass a folder: `swift run Oculuxus ~/src/proj`.
The last project is reopened on launch.

⌘K (Go ▸ Jump to Symbol…) searches the helper's symbol index as you type:
Return opens the match in the active Workspace, ⌘-Return or ⌘-click in a new
one. The app watches the project folder with FSEvents and, when Go files or
module files change, asks the helper to reload them and refreshes open
Workspaces in place. Code from `_test.go` files is hidden unless the Tests
toolbar toggle (or View ▸ Show Code from Tests, ⇧⌘T) is on.

The Navigator lists packages as a tree, nested by import-path segments below
their module, or as a flat list of full import paths. Switch with the control
next to the project picker or View ▸ Packages as Tree / as List (⌃⌘1, ⌃⌘2);
the choice is remembered.

The protocol types (`OcxRequest`, `OcxPackageOutline`, ...) are generated from
`proto/oculuxus/v1/oculuxus.proto` at build time by the swift-protobuf SwiftPM
plugin; `Sources/Oculuxus/swift-protobuf-config.json` points it at the schema.
SwiftPM warns that the config file is unhandled; that is expected.

The helper needs a Go toolchain. The app tries the user's login-shell PATH and
the usual install locations (`/usr/local/go/bin`, `/opt/homebrew/bin`,
`/opt/local/bin`, `~/go/bin`, `~/sdk/go*/bin`); if the helper still finds no
usable Go, the app asks for a Go binary and remembers it (Font, Colors and Go
popover in a Workspace toolbar).

`swift test` includes tests that drive the real helper; they are skipped when
`bin/oculuxus-helper` is missing. `SnapshotTests` renders the Navigator and a
Workspace for a project into a PNG when `OCULUXUS_SNAPSHOT_DIR` is set
(`OCULUXUS_SNAPSHOT_LAYOUT=flat` renders the flat Navigator).

| Directory | What it is |
| --- | --- |
| `Helper/` | `HelperClient` (process, framing, request ids, progress, cancel, shutdown) and locating the helper and Go. |
| `Model/` | `ProjectSession`: the open project, its package list, shared, cancellable request caches, and live reload; `ProjectWatcher` (FSEvents). |
| `Navigator/` | The Navigator window: project picker, project packages, dependencies by module, the standard library, as a tree or a flat list (`PackageTree.swift`). |
| `Workspace/` | Workspace windows: package content pane, source viewer (TextKit 2 `NSTextView`), history. |
| `Search/` | The ⌘K panel and its model. |
| `Settings/` | Font, color scheme, Go binary and recent projects, their popover, and open panels. |
