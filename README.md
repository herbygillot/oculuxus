# Oculuxus

Oculuxus is a native macOS app for reading and exploring Go projects. Open a
folder with a `go.mod` or `go.work` and browse it the way the compiler sees
it: by module, package and declaration, with types resolved, references
found and calls traced, without opening an editor or setting up an IDE.

It is read-only. Oculuxus never changes your code; when you want to edit,
it hands the file and line to your editor.

## Features

- **Navigator sidebar.** Every package in the project, its dependencies by
  module, and the standard library, as a tree or a flat list of import
  paths.
- **Workspace windows.** A package's declarations with their signatures and
  doc comments next to a syntax-highlighted source viewer, with
  back/forward history. Open as many Workspaces as you like.
- **Jump to Symbol (⌘K).** Search every type, function, method and field in
  the project, its dependencies and the standard library as you type.
- **Find References (⇧⌘R) and call hierarchy (⌃⇧⌘H).** Every use of a
  declaration, grouped by package and file, and expandable callers and
  callees trees. Calls through interfaces and function values are labelled.
- **Hover cards.** Rest the pointer on an identifier to see its kind,
  signature, package, doc comment and where it is defined.
- **Build tags and target platform.** View the project as it builds for any
  GOOS/GOARCH and set of build tags.
- **Live reload.** Edit files in your editor and open Workspaces refresh in
  place.
- **Open in Editor (⇧⌘E).** Jump to the current declaration in VS Code,
  Zed, GoLand, Sublime Text, Xcode, a custom command, or the default app.

[app/README.md](app/README.md) describes every feature and shortcut in
detail.

## Requirements

- macOS 14 (Sonoma) or later, on Apple silicon or Intel.
- A Go toolchain on the Mac. Oculuxus uses it to load projects the same way
  `go build` does. It finds Go on your login shell's `PATH` or in the usual
  install locations (`/usr/local/go/bin`, Homebrew, MacPorts, `~/go/bin`,
  `~/sdk/go*/bin`), and asks you to pick a Go binary if it finds none.

To build it you also need Xcode and Go 1.26 or later.

## Building

Each tagged version is published as a zipped app on the
[Releases](https://github.com/herbygillot/oculuxus/releases) page. Those
builds are signed ad hoc, not notarized, so the first time you open one,
Control-click Oculuxus.app and choose Open (or allow it in System Settings ▸
Privacy & Security).

To build the app from source:

```sh
git clone https://github.com/herbygillot/oculuxus.git
cd oculuxus
make
open dist/Oculuxus.app
```

`make` builds `dist/Oculuxus.app`, a universal (arm64 and x86_64) release
build with the Go helper inside. `ARCHS=arm64 make` builds a single
architecture, which is quicker. `make clean` removes everything the build
made.

The app is signed ad hoc, which is enough to run it on the Mac that built
it. Distributing it to others would need a Developer ID signature and
notarization.

### Development

```sh
make build      # build the Go helper into bin/
make app-run    # run the app from the command line using bin/oculuxus-helper
make test       # helper tests
make app-test   # app tests
make lint       # buf lint and go vet
```

You can also open `app/Package.swift` in Xcode. The first build asks you to
trust the swift-protobuf build plugin.

If you change the protocol schema, install the code generators with
`make tools` and run `make generate`. The generated Go code is committed
under `helper/pb/`; the Swift types are generated at build time and are not
committed.

## How it works

Oculuxus is two programs:

- **The app** is written in Swift and SwiftUI. It owns the windows, the
  source viewer (TextKit 2), search, and the file watcher (FSEvents) that
  drives live reload.
- **The helper** (`oculuxus-helper`) is a Go program bundled inside the app.
  It does all of the Go analysis with `go/packages` and `go/types`, the same
  libraries Go's own tools use, so what you see matches what the compiler
  sees: real package boundaries, resolved types, build constraints and
  module versions.

The app starts the helper as a child process and they talk over stdin and
stdout with length-prefixed protobuf messages. One schema,
[`proto/oculuxus/v1/oculuxus.proto`](proto/oculuxus/v1/oculuxus.proto),
generates both the Go and the Swift types.

The helper loads lazily: listing packages needs only metadata, a package is
type-checked when you open it, and a symbol index and a reference index are
built in the background, project packages first, then dependencies and the
standard library. That keeps large projects responsive from the moment they
open. The helper also works on its own from the command line, printing what
the app would receive as JSON; see [helper/README.md](helper/README.md).

## Repository layout

| Directory | What it is |
| --- | --- |
| [`app/`](app/) | The macOS app, a Swift package. |
| [`helper/`](helper/) | The Go helper, a Go module. |
| [`proto/`](proto/) | The app ↔ helper protocol schema. |

## How it was built

Oculuxus has been built mostly by AI. Most of its code, tests and
documentation were written by Claude, Anthropic's AI model, working from
design decisions, direction and review by the project's author.

## License

Oculuxus is released under the [MIT License](LICENSE).
