# Oculuxus app

The macOS app: native SwiftUI, macOS 14 or later. It is a Swift package,
so there is no checked-in Xcode project; open `app/Package.swift` in Xcode,
or build from the command line:

```sh
swift build          # or: xcodebuild -scheme Oculuxus -destination platform=macOS -skipPackagePluginValidation build
swift test
swift run Oculuxus
```

The app runs the Go helper as a child process. It looks for the helper in
`$OCULUXUS_HELPER`, then inside the app bundle (`Contents/MacOS/oculuxus-helper`,
as `make app-bundle` builds it), then at `bin/oculuxus-helper` in this
repository. For development, build that with `make build` at the repository
root. Open a
project with Open Folder… (⌘O), or pass a folder: `swift run Oculuxus ~/src/proj`.
The last project is reopened on launch.

⌘K (Go ▸ Jump to Symbol…) searches the helper's symbol index as you type:
Return opens the match in the active Workspace, ⌘-Return or ⌘-click in a new
one. The app watches the project folder with FSEvents and, when Go files or
module files change, asks the helper to reload them and refreshes open
Workspaces in place. Code from `_test.go` files is hidden unless the Tests
toolbar toggle (or View ▸ Show Code from Tests, ⇧⌘T) is on.

Find References (Go ▸ Find References, ⇧⌘R, or right-click an identifier in
the source or a declaration in the outline) opens a panel at the bottom of
the Workspace with every use, grouped by package and file, one line each
with the identifier highlighted; uses through an interface the method
implements say "via" that interface. It covers the project; the
Dependencies checkbox adds dependencies and the standard library. The app
asks the helper once for what is indexed and shows it, then again, waiting,
for the rest, with the helper's progress in the panel. For a function or
method the panel also has Callers and Callees (Go ▸ Find Callers, ⌃⇧⌘H, and
Find Callees), trees that load one level each time a row is expanded; calls
through interfaces and function values are labelled. Clicking a row shows
that line in the Workspace, ⌘-click in a new one; both go into history.
From the menu, the panel follows the identifier at the source viewer's
insertion point after a click there, and otherwise the selected
declaration. Resting the pointer half a second on an identifier in the
source, or on a reference in an outline signature, shows a hover card:
kind, signature, package, doc comment and where it is defined. Cards are
cached per declaration.

Open in Editor (Go ▸ Open in Editor, ⇧⌘E, or the toolbar button) opens the
shown declaration or file at its line in your editor; right-click a
declaration, or a line in the source, to open that one. Pick the editor in
the Font, Colors, Go and Editor popover: Visual Studio Code, Zed, GoLand,
Sublime Text, Xcode, a custom command with `{file}` and `{line}` (run with
`/bin/sh`), or the file's default app. Automatic uses `$VISUAL` or `$EDITOR`
from your login shell when it names one of those editors, then the first of
them that is installed, then the default app. Editors are found by their
command-line tool on your login shell's PATH, or inside the app.

The Navigator lists packages as a tree, nested by import-path segments below
their module, or as a flat list of full import paths. Switch with the control
next to the project picker or View ▸ Packages as Tree / as List (⌃⌘1, ⌃⌘2);
the choice is remembered.

Every Workspace window has the Navigator as its leading sidebar, a quarter
of the window wide at first; drag its edge to resize it. The sidebar button
at the leading end of the toolbar (or View ▸ Show/Hide Navigator, ⌃⌘S)
collapses it so the Workspace takes the whole width, and pins it again.
While it is collapsed, resting the pointer on the button slides the
Navigator over the Workspace; it goes away when the pointer leaves it and
the button, when you pick a package, or with Escape, and clicking the
button pins it. Clicking a package shows it in that window; ⌘-click opens a
new Workspace. Each Workspace keeps its own sidebar state and width; a new
one copies the active Workspace's, and the last one is used at the next
launch. Full screen pins the sidebar, and the button still works there.
Closing the last Workspace leaves no window open; File ▸ Open Folder… or
Open Recent opens a project in a new one.

A Workspace gives three quarters of its width to the package content pane
at first. Clicking a pane gives it the three quarters, animated; selecting a
declaration (or clicking its name) widens the source viewer instead, to read
it. Dragging the divider turns that off and keeps the split, which new
Workspaces then use too; double-click the divider to go back.

The chip button next to the project picker sets the project's build tags and
target platform (the current one, linux/amd64, darwin/arm64, windows/amd64,
or any GOOS/GOARCH). Applying reloads the project in a new helper: package
list, outlines, sources and symbol index. The choice is remembered per
project folder and shown in Workspace subtitles.

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
`bin/oculuxus-helper` is missing. `SnapshotTests` renders a Workspace with
its Navigator sidebar for a project into a PNG when `OCULUXUS_SNAPSHOT_DIR`
is set (`OCULUXUS_SNAPSHOT_LAYOUT=flat` renders the flat Navigator,
`OCULUXUS_SNAPSHOT_SIDEBAR=collapsed` or `peek` the collapsed or peeking
sidebar).
`ReferencesScreenshotTests` puts a Workspace on screen for `helper/`, opens
the references panel on each tab and a hover card, and captures them with
`screencapture` into `OCULUXUS_SCREENSHOT_DIR`.

| Directory | What it is |
| --- | --- |
| `Helper/` | `HelperClient` (process, framing, request ids, progress, cancel, shutdown) and locating the helper and Go. |
| `Model/` | `ProjectSession`: the open project, its package list, shared, cancellable request caches, and live reload; `ProjectWatcher` (FSEvents). |
| `Navigator/` | The Navigator sidebar's content: project picker, project packages, dependencies by module, the standard library, as a tree or a flat list (`PackageTree.swift`). |
| `Workspace/` | Workspace windows: the Navigator sidebar with its toggle and peek (`NavigatorSidebar.swift`), package content pane, source viewer (TextKit 2 `NSTextView`), history. |
| `Search/` | The ⌘K panel and its model. |
| `References/` | The references and call hierarchy panel and its model. |
| `Hover/` | Hover cards and the presenter that shows and dismisses them. |
| `Settings/` | Font, color scheme, Go binary, editor and recent projects, their popover, open panels, and Open in Editor (`Editor.swift`). |
| `Bundle/` | `make app-bundle`: the bundle script, Info.plist template and icon drawing. |
