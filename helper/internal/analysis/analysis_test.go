package analysis

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

func openTestProject(t *testing.T, dir string) *Project {
	t.Helper()
	ctx := context.Background()
	tc, err := ResolveToolchain(ctx, "")
	if err != nil {
		t.Skipf("no Go toolchain: %v", err)
	}
	p, err := Open(ctx, tc, filepath.Join("testdata", dir), Target{})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return p
}

func TestOpenModule(t *testing.T) {
	p := openTestProject(t, "simple")
	pr := p.Proto()
	if pr.Workspace || !strings.HasSuffix(pr.ConfigFile, "go.mod") {
		t.Errorf("expected go.mod project, got %+v", pr)
	}
	if len(pr.Modules) != 1 || pr.Modules[0].Path != "example.com/simple" {
		t.Errorf("modules = %+v", pr.Modules)
	}
}

func TestOpenWorkspace(t *testing.T) {
	p := openTestProject(t, "work")
	pr := p.Proto()
	if !pr.Workspace {
		t.Fatalf("expected workspace project, got %+v", pr)
	}
	var paths []string
	for _, m := range pr.Modules {
		paths = append(paths, m.Path)
	}
	if strings.Join(paths, ",") != "example.com/alpha,example.com/beta" {
		t.Errorf("modules = %v", paths)
	}
	list, err := p.ListPackages(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	origins := map[string]pb.PackageOrigin{}
	for _, pkg := range list.Packages {
		origins[pkg.Id] = pkg.Origin
	}
	if origins["example.com/alpha"] != pb.PackageOrigin_PROJECT || origins["example.com/beta"] != pb.PackageOrigin_PROJECT {
		t.Errorf("workspace packages not marked PROJECT: %v", origins)
	}
	tp, err := p.Typed(context.Background(), "example.com/beta", false)
	if err != nil {
		t.Fatal(err)
	}
	b := findDecl(tp.Outline().Declarations, "B")
	if b == nil || len(b.Members) != 1 || !b.Members[0].Embedded || b.Members[0].Id != "B.A" {
		t.Errorf("B members = %+v", b)
	}
}

func TestListPackages(t *testing.T) {
	p := openTestProject(t, "simple")
	list, err := p.ListPackages(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var shapes *pb.Package
	stdlib := 0
	for _, pkg := range list.Packages {
		switch {
		case pkg.Id == "example.com/simple/shapes":
			shapes = pkg
		case pkg.Origin == pb.PackageOrigin_STDLIB:
			stdlib++
		}
	}
	if shapes == nil {
		t.Fatal("shapes package not listed")
	}
	if shapes.Origin != pb.PackageOrigin_PROJECT || shapes.Name != "shapes" || shapes.ModulePath != "example.com/simple" {
		t.Errorf("shapes = %+v", shapes)
	}
	if strings.Join(shapes.Imports, ",") != "fmt,io" {
		t.Errorf("imports = %v", shapes.Imports)
	}
	if stdlib == 0 {
		t.Error("no stdlib packages listed")
	}
}

func findDecl(decls []*pb.Declaration, id string) *pb.Declaration {
	for _, d := range decls {
		if d.Id == id {
			return d
		}
		if m := findDecl(d.Members, id); m != nil {
			return m
		}
	}
	return nil
}

func TestOutline(t *testing.T) {
	p := openTestProject(t, "simple")
	tp, err := p.Typed(context.Background(), "example.com/simple/shapes", false)
	if err != nil {
		t.Fatal(err)
	}
	o := tp.Outline()
	if len(o.Errors) > 0 {
		t.Fatalf("errors: %v", o.Errors)
	}
	if !strings.HasPrefix(o.Doc, "Package shapes has") {
		t.Errorf("doc = %q", o.Doc)
	}
	if len(o.Files) != 2 || o.Files[0].Name != "extra.go" {
		t.Errorf("files = %v", o.Files)
	}

	want := map[string]struct {
		kind pb.SymbolKind
		sig  string
	}{
		"Kind":           {pb.SymbolKind_TYPE, "type Kind int"},
		"Round":          {pb.SymbolKind_CONST, "const Round Kind = iota"},
		"Square":         {pb.SymbolKind_CONST, "const Square = 1"},
		"Version":        {pb.SymbolKind_CONST, `const Version = "1.0"`},
		"Default":        {pb.SymbolKind_VAR, "var Default Shape = …"},
		"count":          {pb.SymbolKind_VAR, "var count int"},
		"Shape":          {pb.SymbolKind_INTERFACE, "type Shape interface"},
		"Shape.Stringer": {pb.SymbolKind_FIELD, "fmt.Stringer"},
		"Shape.Area":     {pb.SymbolKind_METHOD, "Area() float64"},
		"Circle":         {pb.SymbolKind_STRUCT, "type Circle struct"},
		"Circle.Radius":  {pb.SymbolKind_FIELD, "Radius float64"},
		"Circle.point":   {pb.SymbolKind_FIELD, "point"},
		"Circle.Area":    {pb.SymbolKind_METHOD, "func (c Circle) Area() float64"},
		"Circle.Scale":   {pb.SymbolKind_METHOD, "func (c *Circle) Scale(f float64)"},
		"Describe":       {pb.SymbolKind_FUNC, "func Describe(w io.Writer, s Shape) error"},
		"Pair":           {pb.SymbolKind_STRUCT, "type Pair[K comparable, V any] struct"},
		"Pair.Swap":      {pb.SymbolKind_METHOD, "func (p Pair[K, V]) Swap() (V, K)"},
	}
	for id, w := range want {
		d := findDecl(o.Declarations, id)
		if d == nil {
			t.Errorf("%s: not in outline", id)
			continue
		}
		if d.Kind != w.kind || d.Signature.Text != w.sig {
			t.Errorf("%s: got %s %q, want %s %q", id, d.Kind, d.Signature.Text, w.kind, w.sig)
		}
	}

	// Members: fields first in declaration order, then methods by file.
	circle := findDecl(o.Declarations, "Circle")
	var ids []string
	for _, m := range circle.Members {
		ids = append(ids, m.Id)
	}
	if got := strings.Join(ids, " "); got != "Circle.Radius Circle.center Circle.point Circle.Scale Circle.Area Circle.Kind Circle.String" {
		t.Errorf("Circle members = %s", got)
	}
	if circle.Doc != "Circle is a round shape." || circle.Location.Line != 37 {
		t.Errorf("Circle doc/location = %q %+v", circle.Doc, circle.Location)
	}
	if round := findDecl(o.Declarations, "Round"); round.Doc != "Round shapes have no corners." {
		t.Errorf("Round doc = %q", round.Doc)
	}

	// Signature tokens: the receiver type and the io.Writer parameter are
	// navigable.
	desc := findDecl(o.Declarations, "Describe")
	targets := map[string]string{}
	for _, tok := range desc.Signature.Tokens {
		if tok.Target != nil {
			targets[desc.Signature.Text[tok.Range.Start:tok.Range.End]] = tok.Target.PackageId + "#" + tok.Target.DeclarationId
		}
	}
	if targets["Writer"] != "io#Writer" || targets["Shape"] != "example.com/simple/shapes#Shape" || targets["io"] != "io#" {
		t.Errorf("Describe targets = %v", targets)
	}
}

func TestDeclarationSource(t *testing.T) {
	p := openTestProject(t, "simple")
	tp, err := p.Typed(context.Background(), "example.com/simple/shapes", false)
	if err != nil {
		t.Fatal(err)
	}
	src, err := tp.DeclarationSource("Circle.String")
	if err != nil {
		t.Fatal(err)
	}
	text := src.Source.Text
	if !strings.HasPrefix(text, "func (c Circle) String() string {") || !strings.HasSuffix(text, "}") {
		t.Errorf("source = %q", text)
	}
	if src.Location.Line != 50 || !strings.HasSuffix(src.Location.File, "shapes.go") {
		t.Errorf("location = %+v", src.Location)
	}
	kinds := map[string]pb.TokenType{}
	targets := map[string]string{}
	for _, tok := range src.Source.Tokens {
		s := text[tok.Range.Start:tok.Range.End]
		kinds[s] = tok.Type
		if tok.Target != nil {
			targets[s] = tok.Target.PackageId + "#" + tok.Target.DeclarationId
		}
	}
	for s, want := range map[string]pb.TokenType{
		"func": pb.TokenType_KEYWORD, "c": pb.TokenType_PARAMETER, "Circle": pb.TokenType_STRUCT_NAME,
		"String": pb.TokenType_METHOD_NAME, "string": pb.TokenType_BUILTIN, "r": pb.TokenType_VARIABLE,
		"fmt": pb.TokenType_NAMESPACE, "Sprintf": pb.TokenType_FUNCTION, "Radius": pb.TokenType_PROPERTY,
		`"circle(%v)"`: pb.TokenType_STRING, "return": pb.TokenType_KEYWORD, ":=": pb.TokenType_OPERATOR,
	} {
		if kinds[s] != want {
			t.Errorf("token %q = %s, want %s", s, kinds[s], want)
		}
	}
	if targets["Radius"] != "example.com/simple/shapes#Circle.Radius" || targets["Sprintf"] != "fmt#Sprintf" {
		t.Errorf("targets = %v", targets)
	}

	// A doc comment is included and marked as documentation.
	src, err = tp.DeclarationSource("Describe")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(src.Source.Text, "// Describe writes") {
		t.Errorf("source = %q", src.Source.Text)
	}
	first := src.Source.Tokens[0]
	if first.Type != pb.TokenType_COMMENT || first.Modifiers&uint32(pb.TokenModifier_DOCUMENTATION) == 0 {
		t.Errorf("first token = %+v", first)
	}

	// A grouped const shows just its spec.
	src, err = tp.DeclarationSource("Square")
	if err != nil {
		t.Fatal(err)
	}
	if src.Source.Text != "Square" {
		t.Errorf("Square source = %q", src.Source.Text)
	}
	if _, err := tp.DeclarationSource("Nope"); err == nil {
		t.Error("expected NOT_FOUND")
	}
}

func TestFileSource(t *testing.T) {
	p := openTestProject(t, "simple")
	tp, err := p.Typed(context.Background(), "example.com/simple/shapes", false)
	if err != nil {
		t.Fatal(err)
	}
	path, _ := filepath.Abs(filepath.Join("testdata", "simple", "shapes", "extra.go"))
	src, err := tp.FileSource(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(src.Source.Text, "package shapes") {
		t.Errorf("text = %q", src.Source.Text)
	}
	if len(src.Declarations) != 1 || src.Declarations[0].DeclarationId != "Circle.Scale" {
		t.Errorf("declarations = %+v", src.Declarations)
	}
	r := src.Declarations[0].Range
	if got := src.Source.Text[r.Start:r.End]; !strings.HasPrefix(got, "// Scale scales") || !strings.HasSuffix(got, "c.Radius *= f }") {
		t.Errorf("range text = %q", got)
	}
}

func TestReload(t *testing.T) {
	p := openTestProject(t, "simple")
	ctx := context.Background()
	if _, err := p.ListPackages(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Typed(ctx, "example.com/simple/shapes", false); err != nil {
		t.Fatal(err)
	}
	file, _ := filepath.Abs(filepath.Join("testdata", "simple", "shapes", "extra.go"))
	resp := p.Reload([]string{file})
	if resp.PackageListChanged || strings.Join(resp.ChangedPackageIds, ",") != "example.com/simple/shapes" {
		t.Errorf("reload = %+v", resp)
	}
	if _, cached := p.typed["example.com/simple/shapes"]; cached {
		t.Error("typed package not dropped")
	}
	if p.list == nil {
		t.Error("package list dropped")
	}

	gomod, _ := filepath.Abs(filepath.Join("testdata", "simple", "go.mod"))
	resp = p.Reload([]string{gomod})
	if !resp.PackageListChanged || p.list != nil {
		t.Errorf("go.mod reload = %+v", resp)
	}
}

func TestOpenTarget(t *testing.T) {
	t.Setenv("OCULUXUS_CACHE_DIR", "off")
	dir := copyProject(t, "simple")
	write := func(name, src string) {
		if err := os.WriteFile(filepath.Join(dir, "shapes", name), []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("only_windows.go", "package shapes\n\nfunc OnWindows() {}\n")
	write("tagged.go", "//go:build extra\n\npackage shapes\n\nfunc Tagged() {}\n")

	ctx := context.Background()
	tc, err := ResolveToolchain(ctx, "")
	if err != nil {
		t.Skipf("no Go toolchain: %v", err)
	}
	has := func(target Target) (windows, tagged bool) {
		t.Helper()
		p, err := Open(ctx, tc, dir, target)
		if err != nil {
			t.Fatalf("Open %+v: %v", target, err)
		}
		defer p.Close()
		tp, err := p.Typed(ctx, "example.com/simple/shapes", false)
		if err != nil {
			t.Fatalf("Typed %+v: %v", target, err)
		}
		decls := tp.Outline().Declarations
		return findDecl(decls, "OnWindows") != nil, findDecl(decls, "Tagged") != nil
	}
	host := Target{GOOS: "darwin", GOARCH: "arm64"}
	if w, tg := has(host); w || tg {
		t.Errorf("darwin/arm64 without tags: windows=%v tagged=%v", w, tg)
	}
	if w, tg := has(Target{GOOS: "windows", GOARCH: "amd64", BuildTags: []string{"extra"}}); !w || !tg {
		t.Errorf("windows/amd64 with extra: windows=%v tagged=%v", w, tg)
	}
}
