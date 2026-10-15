package analysis

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"

	"golang.org/x/tools/go/packages"
	"google.golang.org/protobuf/proto"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// indexFormat is bumped when the indexing rules change, so that caches
// written by an older helper are rebuilt.
const indexFormat = 1

// symbolIndex holds every declaration in the build graph, by name, for
// search. It is built from syntax alone in the background, the project's
// packages first, and cached on disk. A package is re-parsed only when
// its files' names, sizes or modification times change.
//
// Methods are safe for concurrent use.
type symbolIndex struct {
	cachePath string // "" disables the disk cache
	build     string // Go version and build flags; part of the cache key

	// load type-checks packages for the reference index; set by Project.
	load func(ctx context.Context, ids []string) ([]*packages.Package, error)

	mu       sync.Mutex
	scope    []indexTarget                 // the packages to index, project first
	pkgs     map[string]*indexedPkg        // indexed packages by id
	current  map[string]bool               // pkgs checked against the files in scope
	disk     map[string]*pb.IndexedPackage // loaded from the cache file, not yet used
	diskRead bool
	dirty    bool // pkgs differs from the cache file
	cancel   context.CancelFunc
	changed  chan struct{} // closed and replaced whenever pkgs or scope changes
	closed   bool
	wg       sync.WaitGroup

	// References, recorded after the symbols: the project's packages
	// always, dependencies once wantDeps is set. Each half has its own
	// cache file, so a project change never rewrites the dependencies'.
	refs        map[string]*pkgRefs
	refsCurrent map[string]bool
	diskRefs    map[string]*pb.IndexedReferences
	refsRead    [2]bool // project, dependencies: the cache file was read
	refsDirty   [2]bool // project, dependencies
	wantDeps    bool

	parsed    atomic.Int64 // packages parsed, for tests
	typeCheck atomic.Int64 // packages type-checked for references, for tests
}

// indexTarget is a package to index: its id and the files to parse.
type indexTarget struct {
	id     string
	name   string
	origin pb.PackageOrigin
	files  []string
}

type indexedPkg struct {
	target      indexTarget
	fingerprint []byte
	files       []string
	symbols     []indexedSymbol
}

type indexedSymbol struct {
	id        string // "Name" or "Type.Member"
	name      string // the last element of id
	lowerID   string
	kind      pb.SymbolKind
	signature string
	file      uint32 // index into indexedPkg.files
	line      uint32
	column    uint32
}

func newSymbolIndex(cachePath, build string) *symbolIndex {
	return &symbolIndex{
		cachePath:   cachePath,
		build:       build,
		pkgs:        map[string]*indexedPkg{},
		current:     map[string]bool{},
		changed:     make(chan struct{}),
		refs:        map[string]*pkgRefs{},
		refsCurrent: map[string]bool{},
	}
}

// indexCacheDir is where index caches live: $OCULUXUS_CACHE_DIR, or the
// user cache directory. "off" disables caching.
func indexCacheDir() string {
	if dir := os.Getenv("OCULUXUS_CACHE_DIR"); dir != "" {
		if dir == "off" {
			return ""
		}
		return dir
	}
	dir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "Oculuxus", "index")
}

// indexCachePath names the cache file for a project folder.
func indexCachePath(root string) string {
	dir := indexCacheDir()
	if dir == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(root))
	return filepath.Join(dir, filepath.Base(root)+"-"+hex.EncodeToString(sum[:8])+".pb")
}

// notifyLocked wakes everyone waiting for the index to change.
func (x *symbolIndex) notifyLocked() {
	close(x.changed)
	x.changed = make(chan struct{})
}

// update sets the packages to index and (re)starts the background build.
// Packages already indexed with unchanged files are kept.
func (x *symbolIndex) update(scope []indexTarget) {
	x.mu.Lock()
	defer x.mu.Unlock()
	sort.SliceStable(scope, func(i, j int) bool {
		return originRank(scope[i].origin) < originRank(scope[j].origin)
	})
	x.scope = scope
	x.restartLocked()
}

// invalidate forgets the given packages and re-indexes them.
func (x *symbolIndex) invalidate(ids map[string]bool) {
	if len(ids) == 0 {
		return
	}
	x.mu.Lock()
	defer x.mu.Unlock()
	for id := range ids {
		delete(x.pkgs, id)
		delete(x.disk, id)
		delete(x.refs, id)
		delete(x.diskRefs, id)
	}
	if x.scope != nil {
		x.restartLocked()
	}
}

func (x *symbolIndex) restartLocked() {
	if x.closed {
		return
	}
	if x.cancel != nil {
		x.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	x.cancel = cancel
	scope := x.scope
	// Until the new build has checked them, indexed packages are searched
	// but do not count as up to date.
	x.current = map[string]bool{}
	x.refsCurrent = map[string]bool{}
	x.notifyLocked()
	x.wg.Add(1)
	go func() {
		defer x.wg.Done()
		x.run(ctx, scope)
	}()
}

// close stops the background build and waits for it.
func (x *symbolIndex) close() {
	x.mu.Lock()
	x.closed = true
	if x.cancel != nil {
		x.cancel()
	}
	x.mu.Unlock()
	x.wg.Wait()
}

func originRank(o pb.PackageOrigin) int {
	switch o {
	case pb.PackageOrigin_PROJECT:
		return 0
	case pb.PackageOrigin_DEPENDENCY:
		return 1
	}
	return 2
}

// run brings the index up to date with scope: it keeps what is current,
// takes what it can from the disk cache, and parses the rest, project
// packages first. Builds run one at a time; a newer one cancels this one.
func (x *symbolIndex) run(ctx context.Context, scope []indexTarget) {
	x.readCache()

	var todo []indexTarget
	var prints [][]byte
	x.mu.Lock()
	inScope := map[string]bool{}
	for _, t := range scope {
		inScope[t.id] = true
	}
	for id := range x.pkgs {
		if !inScope[id] {
			delete(x.pkgs, id)
			x.dirty = true
		}
	}
	x.mu.Unlock()
	for _, t := range scope {
		if ctx.Err() != nil {
			return
		}
		fp := fingerprint(t.files)
		x.mu.Lock()
		if ctx.Err() != nil {
			x.mu.Unlock()
			return
		}
		if cur, ok := x.pkgs[t.id]; ok && string(cur.fingerprint) == string(fp) {
			if cur.target.name != t.name || cur.target.origin != t.origin {
				// Searches may be reading cur; replace it rather than edit it.
				x.pkgs[t.id] = &indexedPkg{target: t, fingerprint: cur.fingerprint, files: cur.files, symbols: cur.symbols}
			}
			x.current[t.id] = true
		} else if d, ok := x.disk[t.id]; ok && string(d.Fingerprint) == string(fp) {
			x.pkgs[t.id] = fromProto(t, d)
			x.current[t.id] = true
			delete(x.disk, t.id)
			x.dirty = true // the file is rewritten without unused packages
		} else {
			todo = append(todo, t)
			prints = append(prints, fp)
		}
		x.mu.Unlock()
	}
	x.mu.Lock()
	x.notifyLocked()
	x.mu.Unlock()

	// Parse what is left, the project's packages first, saving after each
	// part in case the rest is slow.
	split := 0
	for split < len(todo) && todo[split].origin == pb.PackageOrigin_PROJECT {
		split++
	}
	for _, part := range [][2]int{{0, split}, {split, len(todo)}} {
		if part[0] == part[1] {
			continue
		}
		x.parseAll(ctx, todo[part[0]:part[1]], prints[part[0]:part[1]])
		if ctx.Err() != nil {
			return
		}
		x.save()
	}

	// Then the references, which need type-checking: the project's own
	// packages, and dependencies once something asked for them.
	x.indexRefs(ctx, scope, false)
	x.mu.Lock()
	deps := x.wantDeps
	x.mu.Unlock()
	if deps {
		x.indexRefs(ctx, scope, true)
	}
}

// refBatch is how many packages one go/packages load type-checks for
// the reference index: one `go list` per batch, and at most this many
// packages' syntax and types in memory at once.
const refBatch = 16

// indexRefs brings the references of the project's packages (deps false)
// or of the dependencies and the standard library (deps true) up to date
// with scope, keeping what is current and taking what it can from the
// cache before type-checking the rest in batches.
func (x *symbolIndex) indexRefs(ctx context.Context, scope []indexTarget, deps bool) {
	x.readRefsCache(deps)
	var todo []indexTarget
	var prints [][]byte
	for _, t := range scope {
		if (t.origin == pb.PackageOrigin_PROJECT) == deps {
			continue
		}
		if ctx.Err() != nil {
			return
		}
		x.mu.Lock()
		fp := x.fingerprintLocked(t)
		switch {
		case ctx.Err() != nil:
		case x.refs[t.id] != nil && string(x.refs[t.id].fingerprint) == string(fp):
			x.refsCurrent[t.id] = true
		case x.diskRefs[t.id] != nil && string(x.diskRefs[t.id].Fingerprint) == string(fp):
			x.refs[t.id] = refsFromProto(x.diskRefs[t.id])
			x.refsCurrent[t.id] = true
			delete(x.diskRefs, t.id)
			x.refsDirty[refsHalf(deps)] = true
		default:
			todo = append(todo, t)
			prints = append(prints, fp)
		}
		x.mu.Unlock()
	}
	x.mu.Lock()
	x.notifyLocked()
	x.mu.Unlock()

	for start := 0; start < len(todo); start += refBatch {
		if ctx.Err() != nil {
			return
		}
		end := min(start+refBatch, len(todo))
		x.typeCheckBatch(ctx, todo[start:end], prints[start:end], deps)
		if (start/refBatch)%8 == 7 {
			x.saveRefs(deps)
		}
	}
	if ctx.Err() == nil {
		x.saveRefs(deps)
	}
}

// fingerprintLocked returns a target's file fingerprint, reusing the one
// the syntax phase computed when the package is indexed.
func (x *symbolIndex) fingerprintLocked(t indexTarget) []byte {
	if ip, ok := x.pkgs[t.id]; ok && x.current[t.id] {
		return ip.fingerprint
	}
	return fingerprint(t.files)
}

// typeCheckBatch loads a batch of packages with types and records their
// references. A package that fails to load is recorded with no
// references, so it is not retried until its files change.
func (x *symbolIndex) typeCheckBatch(ctx context.Context, todo []indexTarget, prints [][]byte, deps bool) {
	ids := make([]string, len(todo))
	byID := map[string]int{}
	for i, t := range todo {
		ids[i] = t.id
		byID[t.id] = i
	}
	loaded := map[string]*packages.Package{}
	if x.load != nil {
		pkgs, err := x.load(ctx, ids)
		if err != nil && ctx.Err() != nil {
			return
		}
		for _, pkg := range pkgs {
			if _, ok := byID[pkg.PkgPath]; ok && pkg.TypesInfo != nil {
				loaded[pkg.PkgPath] = pkg
			}
		}
	}
	for i, t := range todo {
		if ctx.Err() != nil {
			return
		}
		r := emptyRefs(prints[i])
		if pkg, ok := loaded[t.id]; ok {
			r = safeExtractRefs(pkg, prints[i])
		}
		x.typeCheck.Add(1)
		x.mu.Lock()
		if ctx.Err() == nil {
			x.refs[t.id] = r
			x.refsCurrent[t.id] = true
			x.refsDirty[refsHalf(deps)] = true
			x.notifyLocked()
		}
		x.mu.Unlock()
	}
}

func emptyRefs(fp []byte) *pkgRefs {
	return &pkgRefs{fingerprint: fp, byTarget: map[refKey][]refSite{}, abstract: map[string][]refKey{}}
}

// safeExtractRefs records a package's references, or none if the
// extraction panics on something go/types produced that this code does
// not expect: a background build must not take the helper down.
func safeExtractRefs(pkg *packages.Package, fp []byte) (r *pkgRefs) {
	defer func() {
		if e := recover(); e != nil {
			fmt.Fprintf(os.Stderr, "oculuxus-helper: indexing references of %s: %v\n", pkg.PkgPath, e)
			r = emptyRefs(fp)
		}
	}()
	return extractRefs(pkg, fp)
}

// requestDeps asks for the dependencies' references to be indexed too.
// The first request starts them; later ones are no-ops.
func (x *symbolIndex) requestDeps() {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.wantDeps {
		return
	}
	x.wantDeps = true
	if x.scope != nil {
		x.restartLocked()
	}
}

func refsHalf(deps bool) int {
	if deps {
		return 1
	}
	return 0
}

// refsCachePath names the cache file for one half of the references.
func (x *symbolIndex) refsCachePath(deps bool) string {
	if x.cachePath == "" {
		return ""
	}
	base := strings.TrimSuffix(x.cachePath, ".pb")
	if deps {
		return base + "-deprefs.pb"
	}
	return base + "-refs.pb"
}

// readRefsCache loads one half of the reference cache, once.
func (x *symbolIndex) readRefsCache(deps bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.diskRefs == nil {
		x.diskRefs = map[string]*pb.IndexedReferences{}
	}
	if x.refsRead[refsHalf(deps)] {
		return
	}
	x.refsRead[refsHalf(deps)] = true
	path := x.refsCachePath(deps)
	if path == "" {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var idx pb.ReferenceIndex
	if err := proto.Unmarshal(data, &idx); err != nil || idx.Format != indexFormat || idx.Build != x.build {
		return
	}
	for _, p := range idx.Packages {
		x.diskRefs[p.PackageId] = p
	}
}

// saveRefs writes one half of the references to its cache file.
func (x *symbolIndex) saveRefs(deps bool) {
	x.mu.Lock()
	path := x.refsCachePath(deps)
	if path == "" || !x.refsDirty[refsHalf(deps)] {
		x.mu.Unlock()
		return
	}
	origin := map[string]pb.PackageOrigin{}
	for _, t := range x.scope {
		origin[t.id] = t.origin
	}
	idx := &pb.ReferenceIndex{Format: indexFormat, Build: x.build}
	for id, r := range x.refs {
		if o, ok := origin[id]; ok && (o == pb.PackageOrigin_PROJECT) != deps {
			idx.Packages = append(idx.Packages, r.toProto(id))
		}
	}
	x.refsDirty[refsHalf(deps)] = false
	x.mu.Unlock()

	sort.Slice(idx.Packages, func(i, j int) bool { return idx.Packages[i].PackageId < idx.Packages[j].PackageId })
	data, err := proto.Marshal(idx)
	if err != nil {
		return
	}
	writeFileAtomic(path, data)
}

// refsEntry is one package's references, as snapshotRefs returns them.
type refsEntry struct {
	target indexTarget
	refs   *pkgRefs
}

// snapshotRefs returns the references of the packages in scope that are
// indexed, and how many of them are up to date, without blocking.
func (x *symbolIndex) snapshotRefs(deps bool) ([]refsEntry, indexStatus, <-chan struct{}) {
	x.mu.Lock()
	defer x.mu.Unlock()
	var out []refsEntry
	var st indexStatus
	for _, t := range x.scope {
		if !deps && t.origin != pb.PackageOrigin_PROJECT {
			continue
		}
		st.total++
		if r, ok := x.refs[t.id]; ok {
			out = append(out, refsEntry{target: t, refs: r})
		}
		if x.refsCurrent[t.id] {
			st.indexed++
		}
	}
	return out, st, x.changed
}

// symbolFor finds an indexed declaration by id, for its kind, signature
// and location.
func (x *symbolIndex) symbolFor(pkgID, declID string) (indexedSymbol, []string, bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	ip, ok := x.pkgs[pkgID]
	if !ok {
		return indexedSymbol{}, nil, false
	}
	for i := range ip.symbols {
		if ip.symbols[i].id == declID {
			return ip.symbols[i], ip.files, true
		}
	}
	return indexedSymbol{}, nil, false
}

// parseAll parses the targets on half the CPUs (this is background work)
// and adds each to the index as it finishes.
func (x *symbolIndex) parseAll(ctx context.Context, todo []indexTarget, prints [][]byte) {
	next := make(chan int)
	var wg sync.WaitGroup
	for range max(1, runtime.GOMAXPROCS(0)/2) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range next {
				ip := parsePackage(todo[i], prints[i])
				x.parsed.Add(1)
				x.mu.Lock()
				if ctx.Err() == nil {
					x.pkgs[ip.target.id] = ip
					x.current[ip.target.id] = true
					x.dirty = true
					x.notifyLocked()
				}
				x.mu.Unlock()
			}
		}()
	}
feed:
	for i := range todo {
		select {
		case next <- i:
		case <-ctx.Done():
			break feed
		}
	}
	close(next)
	wg.Wait()
}

// fingerprint hashes the files' names, sizes and modification times.
func fingerprint(files []string) []byte {
	sorted := append([]string(nil), files...)
	sort.Strings(sorted)
	h := sha256.New()
	var buf [16]byte
	for _, f := range sorted {
		h.Write([]byte(f))
		h.Write([]byte{0})
		if st, err := os.Stat(f); err == nil {
			binary.LittleEndian.PutUint64(buf[:8], uint64(st.Size()))
			binary.LittleEndian.PutUint64(buf[8:], uint64(st.ModTime().UnixNano()))
			h.Write(buf[:])
		}
	}
	return h.Sum(nil)[:16]
}

// parsePackage parses a package's files and records its declarations.
// Files that do not parse are skipped.
func parsePackage(t indexTarget, fp []byte) *indexedPkg {
	ip := &indexedPkg{target: t, fingerprint: fp}
	fset := token.NewFileSet()
	var files []*ast.File
	for _, f := range t.files {
		file, err := parser.ParseFile(fset, f, nil, parser.SkipObjectResolution)
		if file == nil {
			continue
		}
		_ = err // a partial parse still has useful declarations
		files = append(files, file)
	}
	fileIndex := map[string]uint32{}
	var walk func(n *declNode)
	walk = func(n *declNode) {
		sig, _, ok := printSignature(fset, n)
		if !ok {
			sig = n.name
		}
		fi, ok := fileIndex[n.path]
		if !ok {
			fi = uint32(len(ip.files))
			fileIndex[n.path] = fi
			ip.files = append(ip.files, n.path)
		}
		pos := fset.Position(n.node.Pos())
		ip.symbols = append(ip.symbols, newIndexedSymbol(n.id, n.kind, sig, fi, uint32(pos.Line), uint32(pos.Column)))
		for _, m := range n.members {
			walk(m)
		}
	}
	for _, n := range declTree(fset, files, nil) {
		walk(n)
	}
	return ip
}

func newIndexedSymbol(id string, kind pb.SymbolKind, sig string, file, line, column uint32) indexedSymbol {
	name := id
	if i := strings.LastIndexByte(id, '.'); i >= 0 {
		name = id[i+1:]
	}
	return indexedSymbol{
		id: id, name: name, lowerID: strings.ToLower(id),
		kind: kind, signature: sig, file: file, line: line, column: column,
	}
}

func fromProto(t indexTarget, d *pb.IndexedPackage) *indexedPkg {
	ip := &indexedPkg{target: t, fingerprint: d.Fingerprint, files: d.Files}
	ip.symbols = make([]indexedSymbol, 0, len(d.Symbols))
	for _, s := range d.Symbols {
		ip.symbols = append(ip.symbols, newIndexedSymbol(s.DeclarationId, s.Kind, s.Signature, s.File, s.Line, s.Column))
	}
	return ip
}

func (ip *indexedPkg) proto() *pb.IndexedPackage {
	out := &pb.IndexedPackage{PackageId: ip.target.id, Fingerprint: ip.fingerprint, Files: ip.files}
	out.Symbols = make([]*pb.IndexedSymbol, 0, len(ip.symbols))
	for _, s := range ip.symbols {
		out.Symbols = append(out.Symbols, &pb.IndexedSymbol{
			DeclarationId: s.id, Kind: s.kind, Signature: s.signature,
			File: s.file, Line: s.line, Column: s.column,
		})
	}
	return out
}

// readCache loads the cache file once. Anything unreadable, or written
// by another index format or build, is ignored.
func (x *symbolIndex) readCache() {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.diskRead {
		return
	}
	x.diskRead = true
	x.disk = map[string]*pb.IndexedPackage{}
	if x.cachePath == "" {
		return
	}
	data, err := os.ReadFile(x.cachePath)
	if err != nil {
		return
	}
	var idx pb.SymbolIndex
	if err := proto.Unmarshal(data, &idx); err != nil || idx.Format != indexFormat || idx.Build != x.build {
		return
	}
	for _, p := range idx.Packages {
		x.disk[p.PackageId] = p
	}
}

// save writes the indexed packages to the cache file, replacing it.
func (x *symbolIndex) save() {
	x.mu.Lock()
	if x.cachePath == "" || !x.dirty {
		x.mu.Unlock()
		return
	}
	idx := &pb.SymbolIndex{Format: indexFormat, Build: x.build}
	for _, ip := range x.pkgs {
		idx.Packages = append(idx.Packages, ip.proto())
	}
	x.dirty = false
	x.mu.Unlock()

	sort.Slice(idx.Packages, func(i, j int) bool { return idx.Packages[i].PackageId < idx.Packages[j].PackageId })
	data, err := proto.Marshal(idx)
	if err != nil {
		return
	}
	writeFileAtomic(x.cachePath, data)
}

// writeFileAtomic replaces the file at path with data, or leaves it alone.
func writeFileAtomic(path string, data []byte) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".index-*")
	if err != nil {
		return
	}
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Rename(tmp.Name(), path) != nil {
		os.Remove(tmp.Name())
	}
}

// indexStatus counts the packages in scope that are indexed.
type indexStatus struct {
	indexed, total int
}

func (s indexStatus) complete() bool { return s.indexed >= s.total }

// snapshot returns the indexed packages in scope, and how many of them
// are up to date, without blocking the build.
func (x *symbolIndex) snapshot(deps bool) ([]*indexedPkg, indexStatus, <-chan struct{}) {
	x.mu.Lock()
	defer x.mu.Unlock()
	var out []*indexedPkg
	var st indexStatus
	for _, t := range x.scope {
		if !deps && t.origin != pb.PackageOrigin_PROJECT {
			continue
		}
		st.total++
		if ip, ok := x.pkgs[t.id]; ok {
			out = append(out, ip)
		}
		if x.current[t.id] {
			st.indexed++
		}
	}
	return out, st, x.changed
}

// targetsFor turns listed packages into index targets.
func (p *Project) targetsFor(meta map[string]*packages.Package) []indexTarget {
	targets := make([]indexTarget, 0, len(meta))
	for _, pkg := range meta {
		if len(pkg.GoFiles) == 0 {
			continue
		}
		targets = append(targets, indexTarget{
			id:     pkg.PkgPath,
			name:   pkg.Name,
			origin: p.origin(pkg),
			files:  pkg.GoFiles,
		})
	}
	sort.Slice(targets, func(i, j int) bool { return targets[i].id < targets[j].id })
	return targets
}
