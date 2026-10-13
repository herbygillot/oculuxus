package analysis

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// searchFor runs a search that waits for the whole scope to be indexed.
func searchFor(t *testing.T, p *Project, query string, deps bool) []*pb.SymbolMatch {
	t.Helper()
	resp, err := p.Search(context.Background(), &pb.SearchRequest{Query: query, IncludeDependencies: deps, Wait: true}, func(string) {})
	if err != nil {
		t.Fatalf("search %q: %v", query, err)
	}
	if !resp.Complete || resp.IndexedPackages != resp.TotalPackages {
		t.Fatalf("search %q: incomplete %+v", query, resp)
	}
	return resp.Matches
}

func matchIDs(ms []*pb.SymbolMatch) []string {
	var ids []string
	for _, m := range ms {
		id := m.PackageId
		if m.DeclarationId != "" {
			id += "#" + m.DeclarationId
		}
		ids = append(ids, id)
	}
	return ids
}

// copyProject copies a fixture into a temporary folder that tests may edit.
func copyProject(t *testing.T, name string) string {
	t.Helper()
	dst := filepath.Join(t.TempDir(), name)
	err := filepath.Walk(filepath.Join("testdata", name), func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(filepath.Join("testdata", name), path)
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(dst, rel), data, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	return dst
}

func openAt(t *testing.T, dir string) *Project {
	t.Helper()
	ctx := context.Background()
	tc, err := ResolveToolchain(ctx, "")
	if err != nil {
		t.Skipf("no Go toolchain: %v", err)
	}
	p, err := Open(ctx, tc, dir, Target{})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(p.Close)
	return p
}

func TestSearch(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	p := openTestProject(t, "simple")
	defer p.Close()

	ms := searchFor(t, p, "circle", false)
	if len(ms) == 0 || ms[0].DeclarationId != "Circle" || ms[0].Kind != pb.SymbolKind_STRUCT {
		t.Fatalf("circle: %v", matchIDs(ms))
	}
	c := ms[0]
	if c.PackageId != "example.com/simple/shapes" || c.PackageName != "shapes" || c.Origin != pb.PackageOrigin_PROJECT ||
		c.Signature != "type Circle struct" || c.Location.Line != 37 || !strings.HasSuffix(c.Location.File, "shapes.go") {
		t.Errorf("Circle match = %+v", c)
	}
	if len(c.Matched) != 1 || c.Matched[0].Start != 0 || c.Matched[0].End != 6 {
		t.Errorf("Circle ranges = %v", c.Matched)
	}

	// Members match by name; ranges point into "Type.Member".
	ms = searchFor(t, p, "Area", false)
	got := strings.Join(matchIDs(ms), " ")
	if !strings.Contains(got, "shapes#Circle.Area") || !strings.Contains(got, "shapes#Shape.Area") {
		t.Errorf("Area: %s", got)
	}
	for _, m := range ms {
		if m.DeclarationId == "Circle.Area" && (len(m.Matched) != 1 || m.Matched[0].Start != 7 || m.Matched[0].End != 11) {
			t.Errorf("Circle.Area ranges = %v", m.Matched)
		}
	}

	// Dotted queries match "Type.Member" and "pkg.Name".
	if ms := searchFor(t, p, "circle.sc", false); len(ms) == 0 || ms[0].DeclarationId != "Circle.Scale" {
		t.Errorf("circle.sc: %v", matchIDs(ms))
	}
	if ms := searchFor(t, p, "shapes.Describe", false); len(ms) == 0 || ms[0].DeclarationId != "Describe" || ms[0].Signature != "func Describe(w io.Writer, s Shape) error" {
		t.Errorf("shapes.Describe: %v", ms)
	}

	// Packages match by name, and by path with a slash.
	if ms := searchFor(t, p, "shapes", false); len(ms) == 0 || ms[0].Kind != pb.SymbolKind_PACKAGE || ms[0].DeclarationId != "" {
		t.Errorf("shapes: %v", matchIDs(ms))
	}
	if ms := searchFor(t, p, "simple/sha", false); len(ms) != 1 || ms[0].PackageId != "example.com/simple/shapes" {
		t.Errorf("simple/sha: %v", matchIDs(ms))
	}

	// Fuzzy: word starts.
	if ms := searchFor(t, p, "pswap", false); len(ms) == 0 || ms[0].DeclarationId != "Pair.Swap" {
		t.Errorf("pswap: %v", matchIDs(ms))
	}

	// Project scope leaves out the standard library; dependency scope
	// includes it, ranked below the project.
	if ms := searchFor(t, p, "Writer", false); len(ms) != 0 {
		t.Errorf("Writer in project scope: %v", matchIDs(ms))
	}
	ms = searchFor(t, p, "Writer", true)
	if got := matchIDs(ms); len(got) == 0 || !contains(got, "io#Writer") {
		t.Errorf("Writer with deps: %v", got)
	}
	if ms := searchFor(t, p, "Kind", true); len(ms) == 0 || ms[0].PackageId != "example.com/simple/shapes" {
		t.Errorf("Kind: project symbol should rank first: %v", matchIDs(ms))
	}

	if ms := searchFor(t, p, "  ", true); len(ms) != 0 {
		t.Errorf("blank query matched %v", matchIDs(ms))
	}
	resp, _ := p.Search(context.Background(), &pb.SearchRequest{Query: "e", IncludeDependencies: true, Limit: 3}, func(string) {})
	if len(resp.Matches) != 3 {
		t.Errorf("limit: %d matches", len(resp.Matches))
	}
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func TestSearchDoesNotWaitForDependencies(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	p := openTestProject(t, "simple")
	defer p.Close()
	var progress []string
	resp, err := p.Search(context.Background(), &pb.SearchRequest{Query: "Circle", IncludeDependencies: true}, func(m string) { progress = append(progress, m) })
	if err != nil {
		t.Fatal(err)
	}
	// The project is always indexed before a search answers; the standard
	// library may or may not be done.
	if len(resp.Matches) == 0 || resp.Matches[0].DeclarationId != "Circle" || resp.TotalPackages < 10 {
		t.Errorf("resp = %v %d/%d", matchIDs(resp.Matches), resp.IndexedPackages, resp.TotalPackages)
	}
	t.Logf("progress: %v, indexed %d/%d", progress, resp.IndexedPackages, resp.TotalPackages)
}

func TestIndexCache(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", t.TempDir())
	dir := copyProject(t, "simple")

	p := openAt(t, dir)
	searchFor(t, p, "Circle", true)
	if p.index.parsed.Load() == 0 {
		t.Fatal("nothing parsed on first open")
	}
	p.Close()
	if _, err := os.Stat(p.index.cachePath); err != nil {
		t.Fatalf("no cache file: %v", err)
	}

	// Reopening reads everything from the cache.
	p2 := openAt(t, dir)
	if ms := searchFor(t, p2, "Circle", true); len(ms) == 0 || ms[0].DeclarationId != "Circle" || ms[0].Location.Line != 37 {
		t.Fatalf("from cache: %v", matchIDs(ms))
	}
	if n := p2.index.parsed.Load(); n != 0 {
		t.Errorf("parsed %d packages with a warm cache", n)
	}
	p2.Close()

	// A file changed while the project was closed is re-parsed, alone.
	shapes := filepath.Join(dir, "shapes", "extra.go")
	appendFile(t, shapes, "\n// Hexagon has six sides.\nfunc Hexagon() {}\n")
	p3 := openAt(t, dir)
	if ms := searchFor(t, p3, "Hexagon", true); len(ms) != 1 {
		t.Errorf("Hexagon after edit: %v", matchIDs(ms))
	}
	if n := p3.index.parsed.Load(); n != 1 {
		t.Errorf("parsed %d packages after one edit, want 1", n)
	}
}

func appendFile(t *testing.T, path, text string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(text); err != nil {
		t.Fatal(err)
	}
	f.Close()
}

func TestReloadUpdatesIndex(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	dir := copyProject(t, "simple")
	p := openAt(t, dir)
	ctx := context.Background()
	searchFor(t, p, "Circle", false)
	if _, err := p.Typed(ctx, "example.com/simple/shapes", false); err != nil {
		t.Fatal(err)
	}

	// An edit to a file in the package.
	extra := filepath.Join(dir, "shapes", "extra.go")
	appendFile(t, extra, "\nfunc Octagon() {}\n")
	resp := p.Reload([]string{extra})
	if resp.PackageListChanged || strings.Join(resp.ChangedPackageIds, ",") != "example.com/simple/shapes" {
		t.Errorf("reload = %+v", resp)
	}
	if ms := searchFor(t, p, "Octagon", false); len(ms) != 1 {
		t.Errorf("Octagon after reload: %v", matchIDs(ms))
	}
	tp, err := p.Typed(ctx, "example.com/simple/shapes", false)
	if err != nil || findDecl(tp.Outline().Declarations, "Octagon") == nil {
		t.Errorf("outline after reload lacks Octagon (%v)", err)
	}

	// A new file changes the package list; the next search lists again.
	added := filepath.Join(dir, "shapes", "added.go")
	if err := os.WriteFile(added, []byte("package shapes\n\ntype Triangle struct{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if resp := p.Reload([]string{added}); !resp.PackageListChanged {
		t.Errorf("new file: %+v", resp)
	}
	if ms := searchFor(t, p, "Triangle", false); len(ms) != 1 {
		t.Errorf("Triangle after new file: %v", matchIDs(ms))
	}

	// A deleted file too.
	if err := os.Remove(added); err != nil {
		t.Fatal(err)
	}
	if resp := p.Reload([]string{added}); !resp.PackageListChanged {
		t.Errorf("deleted file: %+v", resp)
	}
	if ms := searchFor(t, p, "Triangle", false); len(ms) != 0 {
		t.Errorf("Triangle after delete: %v", matchIDs(ms))
	}

	// A new package.
	if err := os.MkdirAll(filepath.Join(dir, "solids"), 0o755); err != nil {
		t.Fatal(err)
	}
	cube := filepath.Join(dir, "solids", "cube.go")
	if err := os.WriteFile(cube, []byte("package solids\n\nfunc Cube() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if resp := p.Reload([]string{cube}); !resp.PackageListChanged {
		t.Errorf("new package: %+v", resp)
	}
	if ms := searchFor(t, p, "Cube", false); len(ms) != 1 || ms[0].PackageId != "example.com/simple/solids" {
		t.Errorf("Cube: %v", matchIDs(ms))
	}
}

func TestOutlineWithTests(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	p := openTestProject(t, "simple")
	defer p.Close()
	ctx := context.Background()
	if _, err := p.ListPackages(ctx); err != nil {
		t.Fatal(err)
	}

	plain, err := p.Typed(ctx, "example.com/simple/shapes", false)
	if err != nil {
		t.Fatal(err)
	}
	if findDecl(plain.Outline().Declarations, "TestArea") != nil || plain.Outline().ExternalTestPackageId != "" {
		t.Error("test code in the plain outline")
	}

	tp, err := p.Typed(ctx, "example.com/simple/shapes", true)
	if err != nil {
		t.Fatal(err)
	}
	o := tp.Outline()
	test := findDecl(o.Declarations, "TestArea")
	if test == nil || !test.Test || test.Signature.Text != "func TestArea(t *testing.T)" {
		t.Fatalf("TestArea = %+v", test)
	}
	if circle := findDecl(o.Declarations, "Circle"); circle == nil || circle.Test {
		t.Errorf("Circle = %+v", circle)
	}
	if f := findDecl(o.Declarations, "testCircle.name"); f == nil || !f.Test {
		t.Errorf("testCircle.name = %+v", f)
	}
	var names []string
	for _, f := range o.Files {
		names = append(names, f.Name)
		if f.Test != strings.HasSuffix(f.Name, "_test.go") {
			t.Errorf("file %s test = %v", f.Name, f.Test)
		}
	}
	if strings.Join(names, ",") != "extra.go,shapes.go,shapes_test.go" {
		t.Errorf("files = %v", names)
	}
	if o.ExternalTestPackageId != "example.com/simple/shapes_test" {
		t.Errorf("external test package = %q", o.ExternalTestPackageId)
	}
	src, err := tp.DeclarationSource("TestArea")
	if err != nil || !strings.HasPrefix(src.Source.Text, "func TestArea") {
		t.Errorf("TestArea source = %v, %v", src, err)
	}

	// The external test package, with references into the package.
	xt, err := p.Typed(ctx, "example.com/simple/shapes_test", true)
	if err != nil {
		t.Fatal(err)
	}
	if xt.Outline().Name != "shapes_test" || findDecl(xt.Outline().Declarations, "ExampleDescribe") == nil {
		t.Errorf("xtest outline = %+v", xt.Outline())
	}
	ex, err := xt.DeclarationSource("ExampleDescribe")
	if err != nil {
		t.Fatal(err)
	}
	var target *pb.SymbolRef
	for _, tok := range ex.Source.Tokens {
		if ex.Source.Text[tok.Range.Start:tok.Range.End] == "Describe" && tok.Target != nil {
			target = tok.Target
		}
	}
	if target == nil || target.PackageId != "example.com/simple/shapes" || target.DeclarationId != "Describe" {
		t.Errorf("Describe reference = %+v", target)
	}
	if _, err := p.Typed(ctx, "example.com/simple/shapes_test", false); err == nil {
		t.Error("the external test package should need tests")
	}

	// Editing a test file reloads the package and its tests, but not the list.
	testFile, _ := filepath.Abs(filepath.Join("testdata", "simple", "shapes", "shapes_test.go"))
	resp := p.Reload([]string{testFile})
	if resp.PackageListChanged || strings.Join(resp.ChangedPackageIds, ",") != "example.com/simple/shapes,example.com/simple/shapes_test" {
		t.Errorf("test file reload = %+v", resp)
	}
	if len(p.typed) != 0 {
		t.Errorf("typed packages left after reload: %d", len(p.typed))
	}
}

func TestMatchText(t *testing.T) {
	q := func(s string) searchQuery {
		return searchQuery{raw: s, lower: strings.ToLower(s), dot: strings.Contains(s, ".")}
	}
	score := func(query, text string) int {
		s, _ := matchText(q(query), text, strings.ToLower(text))
		return s
	}
	// Tiers: exact > prefix > word start > substring > fuzzy > none.
	order := []struct{ query, text string }{
		{"Serve", "Serve"},
		{"serve", "Serve"},
		{"Serve", "ServeMux"},
		{"Serve", "ListenAndServe"},
		{"erve", "ListenAndServe"},
		{"las", "ListenAndServe"},
	}
	prev := 1 << 30
	for _, o := range order {
		s := score(o.query, o.text)
		if s <= 0 || s >= prev {
			t.Errorf("%q in %q scored %d after %d", o.query, o.text, s, prev)
		}
		prev = s
	}
	// Fuzzy matches must start at a word start.
	for _, miss := range []struct{ query, text string }{{"xyz", "ListenAndServe"}, {"isn", "ListenAndServe"}} {
		if s := score(miss.query, miss.text); s != 0 {
			t.Errorf("%q in %q should not match, scored %d", miss.query, miss.text, s)
		}
	}
	_, ranges := matchText(q("las"), "ListenAndServe", "listenandserve")
	var spans []string
	for _, r := range ranges {
		spans = append(spans, "ListenAndServe"[r.Start:r.End])
	}
	if strings.Join(spans, ",") != "L,A,S" {
		t.Errorf("las ranges = %v", spans)
	}
	_, ranges = matchText(q("srvmux"), "ServeMux", "servemux")
	if len(ranges) == 0 {
		t.Error("srvmux should match ServeMux")
	}

	for _, c := range []struct {
		s    string
		i    int
		want bool
	}{
		{"ListenAndServe", 6, true}, {"ListenAndServe", 7, false}, {"HTTPServer", 4, true},
		{"HTTPServer", 2, false}, {"read_all", 5, true}, {"Base64", 4, true}, {"Circle.Area", 7, true},
	} {
		if got := wordStart(c.s, c.i); got != c.want {
			t.Errorf("wordStart(%q, %d) = %v", c.s, c.i, got)
		}
	}
}
