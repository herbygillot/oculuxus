package analysis

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

const (
	shapesPkg = "example.com/simple/shapes"
	drawPkg   = "example.com/simple/draw"
)

func symbol(pkg, decl string) *pb.SymbolRef {
	return &pb.SymbolRef{PackageId: pkg, DeclarationId: decl}
}

// refsFor finds the references of a declaration, waiting for the index.
func refsFor(t *testing.T, p *Project, pkg, decl string, deps bool) *pb.ReferencesResponse {
	t.Helper()
	resp, err := p.References(context.Background(), &pb.ReferencesRequest{
		At:                  &pb.ReferencesRequest_Symbol{Symbol: symbol(pkg, decl)},
		IncludeDependencies: deps,
		Wait:                true,
	}, func(string) {})
	if err != nil {
		t.Fatalf("references %s#%s: %v", pkg, decl, err)
	}
	if !resp.Complete || resp.IndexedPackages != resp.TotalPackages {
		t.Fatalf("references %s#%s: incomplete %+v", pkg, decl, resp)
	}
	return resp
}

// refLines summarizes references as "pkg:line:text[flags]".
func refLines(refs []*pb.Reference) []string {
	var out []string
	for _, r := range refs {
		s := r.PackageName + ":" + strconv.Itoa(int(r.Location.Line)) + ":" + r.LineText[r.Range.Start:r.Range.End]
		if r.Call {
			s += "()"
		}
		if r.ViaInterface {
			s += " via " + r.Via
		}
		if r.EnclosingId != "" {
			s += " in " + r.EnclosingId
		}
		out = append(out, s)
	}
	return out
}

func TestReferences(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	p := openTestProject(t, "simple")
	defer p.Close()

	// A method: direct calls, plus calls through an interface it
	// implements, marked with the interface.
	resp := refsFor(t, p, shapesPkg, "Circle.Area", false)
	want := []string{
		"draw:18:Area() via shapes.Shape in Total",
		"draw:30:Area() in Print",
		"draw:30:Area() via shapes.Shape in Print",
	}
	if got := refLines(resp.References); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("Circle.Area references:\n got %q\nwant %q", got, want)
	}
	if resp.Total != 3 || resp.Symbol.DeclarationId != "Circle.Area" {
		t.Errorf("Circle.Area response = %+v", resp)
	}
	// The line text loses its indentation, and the range follows.
	first := resp.References[0]
	if first.LineText != "sum += s.Area()" || first.Range.Start != 9 || first.Range.End != 13 || first.Location.Column != 12 {
		t.Errorf("first reference = %+v", first)
	}

	// A function.
	resp = refsFor(t, p, shapesPkg, "Describe", false)
	want = []string{"draw:25:Describe() in Print", "draw:33:Describe() in Print"}
	if got := refLines(resp.References); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("Describe references:\n got %q\nwant %q", got, want)
	}

	// A field: selectors in its own package, and a composite literal
	// key in another. The project's packages sort by id.
	resp = refsFor(t, p, shapesPkg, "Circle.Radius", false)
	want = []string{
		"draw:12:Radius in Unit",
		"shapes:4:Radius in Circle.Scale",
		"shapes:24:Radius in Default",
		"shapes:46:Radius in Circle.Area",
		"shapes:46:Radius in Circle.Area",
		"shapes:51:Radius in Circle.String",
	}
	if got := refLines(resp.References); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("Circle.Radius references:\n got %q\nwant %q", got, want)
	}

	// The limit caps the list but not the total.
	limited, err := p.References(context.Background(), &pb.ReferencesRequest{
		At: &pb.ReferencesRequest_Symbol{Symbol: symbol(shapesPkg, "Circle.Radius")}, Wait: true, Limit: 2,
	}, func(string) {})
	if err != nil || len(limited.References) != 2 || limited.Total != 6 {
		t.Errorf("limited = %+v, %v", limited, err)
	}

	// Pair's only use is as its own method's receiver type.
	if resp := refsFor(t, p, shapesPkg, "Pair", false); strings.Join(refLines(resp.References), "|") != "shapes:67:Pair in Pair.Swap" {
		t.Errorf("Pair references = %v", refLines(resp.References))
	}
	// Nothing refers to Other.
	if resp := refsFor(t, p, shapesPkg, "Other", false); len(resp.References) != 0 || resp.Total != 0 {
		t.Errorf("Other references = %v", refLines(resp.References))
	}
}

func TestReferencesAtPosition(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	p := openTestProject(t, "simple")
	defer p.Close()
	file, src := fixtureFile(t, "simple", "draw", "draw.go")

	// A local variable: its uses come straight from the type-checked
	// package, with no declaration id.
	resp, err := p.References(context.Background(), &pb.ReferencesRequest{
		At:        &pb.ReferencesRequest_Position{Position: &pb.Position{File: file, Offset: uint32(strings.Index(src, "sum :="))}},
		PackageId: drawPkg,
	}, func(string) {})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"draw:18:sum in Total", "draw:20:sum in Total"}
	if got := refLines(resp.References); strings.Join(got, "|") != strings.Join(want, "|") || !resp.Complete || resp.Symbol != nil {
		t.Errorf("sum references:\n got %q (%+v)\nwant %q", got, resp, want)
	}

	// A position on a use of a declaration resolves to that declaration.
	resp, err = p.References(context.Background(), &pb.ReferencesRequest{
		At:        &pb.ReferencesRequest_Position{Position: &pb.Position{File: file, Offset: uint32(strings.Index(src, "Describe(w, Unit)"))}},
		PackageId: drawPkg,
		Wait:      true,
	}, func(string) {})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Symbol == nil || resp.Symbol.PackageId != shapesPkg || resp.Symbol.DeclarationId != "Describe" || len(resp.References) != 2 {
		t.Errorf("Describe by position = %+v", resp)
	}

	// Whitespace has no identifier.
	_, err = p.References(context.Background(), &pb.ReferencesRequest{
		At:        &pb.ReferencesRequest_Position{Position: &pb.Position{File: file, Offset: uint32(strings.Index(src, " := 0.0"))}},
		PackageId: drawPkg,
	}, func(string) {})
	if e, ok := err.(*Error); !ok || e.Code != pb.Error_NOT_FOUND {
		t.Errorf("whitespace: err = %v", err)
	}
}

// fixtureFile returns the absolute path and contents of a fixture file.
func fixtureFile(t *testing.T, parts ...string) (string, string) {
	t.Helper()
	rel := filepath.Join(append([]string{"testdata"}, parts...)...)
	abs, err := filepath.Abs(rel)
	if err != nil {
		t.Fatal(err)
	}
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		abs = real
	}
	data, err := os.ReadFile(abs)
	if err != nil {
		t.Fatal(err)
	}
	return abs, string(data)
}

func TestReferencesInDependencies(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	p := openTestProject(t, "simple")
	defer p.Close()

	// Without dependencies, only the project's use of fmt.Sprintf.
	resp := refsFor(t, p, "fmt", "Sprintf", false)
	if got := refLines(resp.References); strings.Join(got, "|") != "shapes:52:Sprintf() in Circle.String" {
		t.Errorf("Sprintf in project: %q", got)
	}
	// With them, the standard library's uses of errors.New too, project
	// first, each with the line it is on.
	resp = refsFor(t, p, "errors", "New", true)
	if resp.TotalPackages < 10 || resp.Total < 20 || len(resp.References) != int(resp.Total) {
		t.Fatalf("errors.New with dependencies: %d of %d packages, %d references", resp.IndexedPackages, resp.TotalPackages, resp.Total)
	}
	seen := map[string]bool{}
	for _, r := range resp.References {
		seen[r.PackageId] = true
		if r.Origin != pb.PackageOrigin_STDLIB || !r.Call || r.LineText[r.Range.Start:r.Range.End] != "New" {
			t.Errorf("errors.New reference = %+v", r)
		}
	}
	if !seen["io"] || !seen["os"] {
		t.Errorf("errors.New references miss io or os: %v", seen)
	}
}

func TestReferenceCache(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", t.TempDir())
	dir := copyProject(t, "simple")

	p := openAt(t, dir)
	if resp := refsFor(t, p, shapesPkg, "Describe", true); resp.Total != 2 {
		t.Fatalf("Describe: %v", refLines(resp.References))
	}
	if p.index.typeCheck.Load() < 3 {
		t.Fatalf("type-checked %d packages on first open", p.index.typeCheck.Load())
	}
	p.Close()
	for _, deps := range []bool{false, true} {
		if _, err := os.Stat(p.index.refsCachePath(deps)); err != nil {
			t.Fatalf("no reference cache: %v", err)
		}
	}

	// Reopening reads everything from the cache, dependencies included.
	p2 := openAt(t, dir)
	if resp := refsFor(t, p2, shapesPkg, "Describe", true); resp.Total != 2 || resp.TotalPackages < 10 {
		t.Fatalf("from cache: %v (%d packages)", refLines(resp.References), resp.TotalPackages)
	}
	if n := p2.index.typeCheck.Load(); n != 0 {
		t.Errorf("type-checked %d packages with a warm cache", n)
	}
	p2.Close()

	// A file changed while the project was closed is re-checked, alone.
	draw := filepath.Join(dir, "draw", "draw.go")
	appendFile(t, draw, "\n// Twice describes the unit circle twice.\nfunc Twice(w io.Writer) { Print(w); Print(w) }\n")
	p3 := openAt(t, dir)
	resp := refsFor(t, p3, drawPkg, "Print", false)
	if got := refLines(resp.References); strings.Join(got, "|") != "draw:37:Print() in Twice|draw:37:Print() in Twice" {
		t.Errorf("Print after edit: %q", got)
	}
	if n := p3.index.typeCheck.Load(); n != 1 {
		t.Errorf("type-checked %d packages after one edit, want 1", n)
	}
	p3.Close()
}

func TestReloadUpdatesReferences(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	dir := copyProject(t, "simple")
	p := openAt(t, dir)
	if resp := refsFor(t, p, drawPkg, "Total", false); resp.Total != 0 {
		t.Fatalf("Total before edit: %v", refLines(resp.References))
	}
	draw := filepath.Join(dir, "draw", "draw.go")
	appendFile(t, draw, "\nvar _ = Total(nil)\n")
	p.Reload([]string{draw})
	// A blank var has no declaration id, so the use has no enclosing one.
	if resp := refsFor(t, p, drawPkg, "Total", false); strings.Join(refLines(resp.References), "|") != "draw:36:Total()" {
		t.Errorf("Total after edit: %v", refLines(resp.References))
	}
}

func TestCallHierarchy(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	p := openTestProject(t, "simple")
	defer p.Close()
	hierarchy := func(pkg, decl string, dir pb.CallHierarchyRequest_Direction) *pb.CallHierarchyResponse {
		t.Helper()
		resp, err := p.CallHierarchy(context.Background(), &pb.CallHierarchyRequest{Symbol: symbol(pkg, decl), Direction: dir, Wait: true}, func(string) {})
		if err != nil {
			t.Fatalf("%s#%s %v: %v", pkg, decl, dir, err)
		}
		if !resp.Complete {
			t.Fatalf("%s#%s %v: incomplete", pkg, decl, dir)
		}
		return resp
	}
	summarize := func(items []*pb.CallHierarchyItem) []string {
		var out []string
		for _, it := range items {
			s := it.Signature + " [" + it.CallKind.String()
			if it.Via != "" {
				s += " " + it.Via
			}
			s += "] " + strings.Join(refLines(it.Sites), ", ")
			if it.Symbol != nil && it.Symbol.DeclarationId != "" {
				s = it.Symbol.DeclarationId + ": " + s
			}
			out = append(out, s)
		}
		return out
	}

	// Callers of a function, grouped by the function that calls it.
	resp := hierarchy(shapesPkg, "Describe", pb.CallHierarchyRequest_CALLERS)
	want := []string{"Print: func Print(w io.Writer) error [DIRECT] draw:25:Describe() in Print, draw:33:Describe() in Print"}
	if got := summarize(resp.Items); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("callers of Describe:\n got %q\nwant %q", got, want)
	}
	if it := resp.Items[0]; it.Kind != pb.SymbolKind_FUNC || it.Origin != pb.PackageOrigin_PROJECT || it.Location == nil || it.Location.Line != 24 {
		t.Errorf("Print item = %+v", it)
	}

	// Callers of a method include calls through an interface.
	resp = hierarchy(shapesPkg, "Circle.Area", pb.CallHierarchyRequest_CALLERS)
	want = []string{
		"Total: func Total(ss []shapes.Shape) float64 [VIA_INTERFACE shapes.Shape] draw:18:Area() via shapes.Shape in Total",
		"Print: func Print(w io.Writer) error [DIRECT] draw:30:Area() in Print, draw:30:Area() via shapes.Shape in Print",
	}
	if got := summarize(resp.Items); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("callers of Circle.Area:\n got %q\nwant %q", got, want)
	}

	// Callees: direct calls, a call through an interface, and a
	// function value, in order of first call.
	resp = hierarchy(drawPkg, "Print", pb.CallHierarchyRequest_CALLEES)
	want = []string{
		"Describe: func Describe(w io.Writer, s Shape) error [DIRECT] draw:25:Describe() in Print, draw:33:Describe() in Print",
		"Circle.Scale: func (c *Circle) Scale(f float64) [DIRECT] draw:29:Scale() in Print",
		"Circle.Area: func (c Circle) Area() float64 [DIRECT] draw:30:Area() in Print",
		"Shape.Area: Area() float64 [VIA_INTERFACE shapes.Shape] draw:30:Area() in Print",
		"var report func(float64) [FUNCTION_VALUE] draw:32:report() in Print",
	}
	if got := summarize(resp.Items); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("callees of Print:\n got %q\nwant %q", got, want)
	}
	if it := resp.Items[0]; it.Kind != pb.SymbolKind_FUNC || it.PackageName != "shapes" || it.Origin != pb.PackageOrigin_PROJECT || it.Location == nil || it.Location.Line != 56 {
		t.Errorf("Describe item = %+v", it)
	}
	if it := resp.Items[4]; it.Kind != pb.SymbolKind_VAR || it.Symbol == nil || it.Symbol.DeclarationId != "" || it.Location == nil || it.Location.Line != 31 {
		t.Errorf("report item = %+v", it)
	}

	// A declaration without calls.
	if resp := hierarchy(shapesPkg, "Circle.Kind", pb.CallHierarchyRequest_CALLEES); len(resp.Items) != 0 {
		t.Errorf("callees of Circle.Kind = %v", summarize(resp.Items))
	}
}

func TestHover(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	p := openTestProject(t, "simple")
	defer p.Close()
	file, src := fixtureFile(t, "simple", "draw", "draw.go")
	at := func(needle string, skip int) *pb.HoverRequest {
		return &pb.HoverRequest{
			PackageId: drawPkg,
			At:        &pb.HoverRequest_Position{Position: &pb.Position{File: file, Offset: uint32(strings.Index(src, needle) + skip)}},
		}
	}
	hover := func(req *pb.HoverRequest) *pb.Hover {
		t.Helper()
		resp, err := p.Hover(context.Background(), req)
		if err != nil {
			t.Fatalf("hover: %v", err)
		}
		return resp.Hover
	}
	check := func(h *pb.Hover, kind, signature, pkg, decl string) {
		t.Helper()
		if h == nil {
			t.Errorf("no hover, want %s %q", kind, signature)
			return
		}
		if h.Kind != kind || h.Signature.Text != signature {
			t.Errorf("hover = %s %q, want %s %q", h.Kind, h.Signature.Text, kind, signature)
		}
		if pkg == "" {
			if h.Target != nil {
				t.Errorf("hover %q has target %v", signature, h.Target)
			}
		} else if h.Target == nil || h.Target.PackageId != pkg || h.Target.DeclarationId != decl {
			t.Errorf("hover %q target = %v, want %s#%s", signature, h.Target, pkg, decl)
		}
	}

	// A function in another project package: the outline signature,
	// with its doc and location.
	h := hover(at("shapes.Describe(w, Unit)", 7))
	check(h, "func", "func Describe(w io.Writer, s Shape) error", shapesPkg, "Describe")
	if h.Doc != "Describe writes a description of s to w." || h.PackageName != "shapes" || h.Location == nil || h.Location.Line != 56 {
		t.Errorf("Describe hover = %+v", h)
	}
	if len(h.Signature.Tokens) == 0 || h.Signature.Tokens[0].Type != pb.TokenType_KEYWORD {
		t.Errorf("Describe signature tokens = %v", h.Signature.Tokens)
	}
	// A struct field used as a composite literal key.
	check(hover(at("Radius: 1", 0)), "field", "Radius float64", shapesPkg, "Circle.Radius")
	// An interface method, through the interface.
	check(hover(at("s.Area()", 2)), "method", "Area() float64", shapesPkg, "Shape.Area")
	// A standard library type, with its doc.
	h = hover(at("io.Writer", 3))
	check(h, "interface", "type Writer interface", "io", "Writer")
	if !strings.HasPrefix(h.Doc, "Writer is the interface") || h.PackageId != "io" {
		t.Errorf("io.Writer hover = %+v", h)
	}
	// A package name.
	h = hover(at("os.Stdout", 0))
	check(h, "package", `package os // "os"`, "os", "")
	if !strings.HasPrefix(h.Doc, "Package os ") {
		t.Errorf("os hover doc = %q", h.Doc)
	}
	// Locals and parameters have no declaration to navigate to.
	check(hover(at("sum += ", 0)), "local variable", "var sum float64", "", "")
	check(hover(at("w io.Writer", 0)), "parameter", "var w io.Writer", "", "")
	check(hover(at("float64 {", 0)), "builtin", "type float64", "", "")
	// Nothing at whitespace or in a string.
	if h := hover(at(" := 0.0", 0)); h != nil {
		t.Errorf("whitespace hover = %+v", h)
	}
	if h := hover(at(`"io"`, 1)); h != nil {
		t.Errorf("import path hover = %+v", h)
	}

	// By declaration.
	resp, err := p.Hover(context.Background(), &pb.HoverRequest{At: &pb.HoverRequest_Symbol{Symbol: symbol(shapesPkg, "Circle")}})
	if err != nil {
		t.Fatal(err)
	}
	check(resp.Hover, "struct", "type Circle struct", shapesPkg, "Circle")
	if resp.Hover.Doc != "Circle is a round shape." || resp.Hover.Location.Line != 37 {
		t.Errorf("Circle hover = %+v", resp.Hover)
	}
	resp, err = p.Hover(context.Background(), &pb.HoverRequest{At: &pb.HoverRequest_Symbol{Symbol: symbol(shapesPkg, "")}})
	if err != nil {
		t.Fatal(err)
	}
	check(resp.Hover, "package", `package shapes // "example.com/simple/shapes"`, shapesPkg, "")
	if resp.Hover.Doc != "Package shapes has a few declarations of every kind." {
		t.Errorf("shapes hover doc = %q", resp.Hover.Doc)
	}
}
