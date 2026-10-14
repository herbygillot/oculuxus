# Oculuxus

A macOS app for examining and browsing Go projects.

The app is native Swift/SwiftUI. It bundles a Go helper that does all the
analysis and talks to the app over a small protobuf protocol. See the
[Design v0](https://claude.ai/code/artifact/5440dcac-59a2-4224-a45c-2950b132d536)
document for the design.

| Directory | What it is |
| --- | --- |
| `proto/` | The app ↔ helper protocol schema (`oculuxus/v1/oculuxus.proto`). One file generates the Go and the Swift types. |
| `helper/` | The Go helper: a Go module that loads projects with `go/packages` and `go/types`. See [helper/README.md](helper/README.md). |
| `app/` | The macOS app, a Swift package that runs the helper from `bin/` during development. See [app/README.md](app/README.md). |

## Building the app

```sh
make
```

(or `make all`, or `make app-bundle`) builds `dist/Oculuxus.app`: a release build of the app with the helper
inside it at `Contents/MacOS/oculuxus-helper`, an Info.plist, an icon drawn
by `app/Bundle/make-icon.swift`, and an ad-hoc signature. Both executables
are universal (arm64 and x86_64); `ARCHS=arm64 make app-bundle` builds one
architecture, which is quicker. It needs Xcode (for SwiftPM's
multi-architecture builds, `lipo` and `iconutil`) and Go. Open the app from
Finder or with `open dist/Oculuxus.app`; it needs a Go toolchain on the Mac
to analyze projects, and finds it as described in
[app/README.md](app/README.md). The ad-hoc signature is enough to run the
app on the Mac that built it; giving it to others needs a Developer ID
signature and notarization. `make clean` removes everything the build
made: `bin/`, `dist/` and `app/.build`.

For development, `make build && make app-run` runs the app from the
command line with the helper from `bin/`.

## Regenerating protocol code

Install [buf](https://buf.build) and `protoc-gen-go`, then:

```sh
make generate
```

The generated Go code is committed under `helper/pb/`. The Swift types are
generated at build time by the swift-protobuf SwiftPM plugin and are not
committed.
