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

# Search the symbol index (-deps: dependencies and the stdlib too).
./oculuxus-helper -deps search ~/src/some-go-project http.Server

# Every use of a declaration, and who calls a function or what it calls.
./oculuxus-helper refs ~/src/some-go-project github.com/org/project/pkg Server.ListenAndServe
./oculuxus-helper callers ~/src/some-go-project github.com/org/project/pkg Server.ListenAndServe
./oculuxus-helper callees ~/src/some-go-project github.com/org/project/pkg Server.ListenAndServe

# The identifier at a byte offset in a file, as a hover card.
./oculuxus-helper hover ~/src/some-go-project github.com/org/project/pkg /path/to/server.go 1234
```

Each subcommand prints the protocol response as JSON. Flags: `-go PATH`
picks a Go binary, `-tags a,b` sets build tags, `-goos` and `-goarch`
pick the target platform, `-tests` includes
`_test.go` files in `outline`, `source`, `file` and `hover`, `-deps` has
`search`, `refs` and `callers` cover dependencies and the standard library
too, and `-debug-json` logs progress (and, in `serve` mode, every message,
and for `search` and `refs` their timings) to stderr.

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
6. `Search` for ⌘K, at any time after `OpenProject`.
7. `References` for "who uses this", `CallHierarchy` for one level of
   callers or callees, and `Hover` for the card shown when the pointer
   rests on an identifier (by position in a file, or by declaration).

Outline and source requests take `include_tests` to show code from
`_test.go` files. The package's external test package (`package foo_test`)
then has its own id, `PackageOutline.external_test_package_id`.

## Symbol index

The first `ListPackages` starts building a symbol index in the background:
every declaration, method, field and interface method, parsed from syntax
alone (nothing is type-checked), the project's packages first, then
dependencies and the standard library. It never delays other requests. A
`Search` waits for the project's packages, sending `Progress`, and searches
dependencies as far as they are indexed (`complete` says whether that is all
of them).

The index is saved in the protocol's own format (`SymbolIndex` in the
schema) under `~/Library/Caches/Oculuxus/index/`, one file per project, so
reopening a project only re-parses packages whose files changed (by name,
size and modification time). `OCULUXUS_CACHE_DIR` moves the cache; `off`
disables it. `Reload` re-indexes the changed packages.

## Reference index

Once the project's packages are in the symbol index, the helper
type-checks them in the background too, in batches, and records every
reference go/types resolves to a navigable declaration: the identifier's
position, whether it is called, the declaration that contains it, and
whether the target is an interface method. `References` and the callers
side of `CallHierarchy` answer from that index; they wait for the project's
packages, sending `Progress`, like `Search`. For a concrete method, uses of
an interface method it implements are included and marked `via_interface`
with the interface's name.

Dependencies and the standard library are only type-checked once a request
sets `include_dependencies`; until then those requests cover the project
alone. The references live in two more cache files next to the symbol
index, one for the project's packages and one for dependencies, so an edit
in the project never rewrites the larger file. On golang.org/x/tools the
project's 215 packages take about 18 seconds cold and nothing warm; its 267
dependencies another 5 seconds.

Callees need no index: they come from the function's own body. Calls
through an interface or a function value are marked, since their target is
not known statically.

Every request has an id; responses may come back in any order, with
`Progress` messages before the final one. `Cancel` stops a request, which
then finishes with a `CANCELLED` error.

Highlighted text (`Text`) carries non-overlapping tokens with byte ranges
into the text, a token type modelled on LSP semantic tokens, and, where the
identifier resolves to a declaration, a `SymbolRef` the app can navigate to.

## Layout

- `cmd/oculuxus-helper`: the binary.
- `internal/server`: framing, request dispatch, cancellation.
- `internal/analysis`: project loading, the package list, outlines,
  highlighting, the symbol index and search (`index.go`, `search.go`), the
  reference index (`refs.go`), references and call hierarchy
  (`references.go`), and hover cards (`hover.go`).
- `pb/`: generated protocol types. Regenerate with `make generate` at the
  repository root.
