# oculuxus-helper

The Go side of Oculuxus. The app launches this binary and talks to it over
stdin/stdout; it can also be run by hand on any Go project to see what the
app will get.

## Try it on a project

```sh
cd helper
go build -o oculuxus-helper ./cmd/oculuxus-helper

# Every package in the build graph (project, dependencies, stdlib).
./oculuxus-helper packages ~/src/some-go-project

# A package's declarations with signatures only.
./oculuxus-helper outline ~/src/some-go-project github.com/org/project/pkg

# One declaration's source with highlight spans. "Type.Method" for members.
./oculuxus-helper source ~/src/some-go-project github.com/org/project/pkg Server.ListenAndServe

# A whole file with highlight spans and declaration ranges.
./oculuxus-helper file ~/src/some-go-project net/http /usr/local/go/src/net/http/server.go
```

Each subcommand prints the protocol response as JSON. Flags: `-go PATH`
picks a Go binary, `-tags a,b` sets build tags, `-debug-json` logs
progress (and, in `serve` mode, every message) to stderr.

The project is the folder you pass. The helper looks for `go.work`, then
`go.mod`, there. Dependencies and the standard library can be outlined too;
they resolve the way they would when building the project.

## Protocol

`serve` (the default) reads `Request` messages from stdin and writes
`Response` messages to stdout, each prefixed with its length as a varint
(`protodelim` in Go, `BinaryDelimited` in swift-protobuf). The schema is
`proto/oculuxus/v1/oculuxus.proto`, which documents the request flow:

1. `OpenProject` with the folder the user picked.
2. `ListPackages` for the Navigator. Metadata only, no type-checking.
3. `PackageOutline` when a package is opened. This type-checks the package
   and keeps it in memory.
4. `DeclarationSource` when a declaration is clicked, or `FileSource` for
   the whole file.
5. `Reload` with the files that changed on disk; the response says which
   packages to refresh and whether the package list changed.

Every request has an id; responses may come back in any order, with
`Progress` messages before the final one. `Cancel` stops a request, which
then finishes with a `CANCELLED` error.

Highlighted text (`Text`) carries non-overlapping tokens with byte ranges
into the text, a token type modelled on LSP semantic tokens, and, where the
identifier resolves to a declaration, a `SymbolRef` the app can navigate to.

## Layout

- `cmd/oculuxus-helper`: the binary.
- `internal/server`: framing, request dispatch, cancellation.
- `internal/analysis`: project loading, the package list, outlines, and
  highlighting.
- `pb/`: generated protocol types. Regenerate with `make generate` at the
  repository root.
