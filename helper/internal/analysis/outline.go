package analysis

import (
	"bytes"
	"go/ast"
	"go/printer"
	"go/token"
	"go/types"
	"regexp"
	"sort"
	"strings"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// Outline returns the package's declarations with signatures only.
func (tp *typedPackage) Outline() *pb.PackageOutline { return tp.outline }

func (tp *typedPackage) buildOutline() *pb.PackageOutline {
	out := &pb.PackageOutline{
		PackageId: tp.pkg.PkgPath,
		Name:      tp.pkg.Name,
	}
	for _, f := range tp.pkg.CompiledGoFiles {
		out.Files = append(out.Files, &pb.File{Path: f, Name: fileName(f)})
	}
	sort.Slice(out.Files, func(i, j int) bool { return out.Files[i].Name < out.Files[j].Name })
	out.Doc = tp.packageDoc()
	for _, n := range tp.roots {
		out.Declarations = append(out.Declarations, tp.declProto(n))
	}
	for _, e := range tp.pkg.Errors {
		out.Errors = append(out.Errors, e.Error())
	}
	return out
}

// packageDoc returns the package comment, taking the one from doc.go when
// several files have one, as go/doc does.
func (tp *typedPackage) packageDoc() string {
	var best *ast.CommentGroup
	for _, f := range tp.pkg.Syntax {
		if f.Doc == nil {
			continue
		}
		name := fileName(tp.fset.File(f.Pos()).Name())
		if best == nil || name == "doc.go" {
			best = f.Doc
		}
	}
	if best == nil {
		return ""
	}
	return strings.TrimSpace(best.Text())
}

func (tp *typedPackage) declProto(n *declNode) *pb.Declaration {
	d := &pb.Declaration{
		Id:        n.id,
		Kind:      n.kind,
		Name:      n.name,
		Exported:  exported(n.name),
		Signature: tp.signature(n),
		Location:  tp.location(n.node.Pos()),
	}
	if n.doc != nil {
		d.Doc = strings.TrimSpace(n.doc.Text())
	}
	if f, ok := n.node.(*ast.Field); ok && len(f.Names) == 0 {
		d.Embedded = true
	}
	for _, m := range n.members {
		d.Members = append(d.Members, tp.declProto(m))
	}
	return d
}

func (tp *typedPackage) location(pos token.Pos) *pb.Location {
	p := tp.fset.Position(pos)
	return &pb.Location{File: p.Filename, Line: uint32(p.Line), Column: uint32(p.Column)}
}

// signature renders one declaration as a single highlighted line. The
// node is printed with go/printer, without its body or members, and the
// identifiers in the printed text are matched in order to the identifiers
// in the syntax so that each keeps its type information.
func (tp *typedPackage) signature(n *declNode) *pb.Text {
	var node ast.Node
	var idents []*ast.Ident
	switch v := n.node.(type) {
	case *ast.FuncDecl:
		c := *v
		c.Body = nil
		c.Doc = nil
		node = &c
		idents = collectIdents(&c)
	case *ast.TypeSpec:
		c := *v
		c.Doc = nil
		c.Comment = nil
		switch v.Type.(type) {
		case *ast.StructType:
			c.Type = &ast.StructType{Struct: v.Type.Pos(), Fields: &ast.FieldList{}}
		case *ast.InterfaceType:
			c.Type = &ast.InterfaceType{Interface: v.Type.Pos(), Methods: &ast.FieldList{}}
		}
		node = &ast.GenDecl{Tok: token.TYPE, Specs: []ast.Spec{&c}}
		idents = collectIdents(&c)
	case *ast.ValueSpec:
		c := *v
		c.Doc = nil
		c.Comment = nil
		// Show only this name; a spec can declare several.
		c.Names = []*ast.Ident{findIdent(v.Names, n.name)}
		if len(v.Values) == len(v.Names) && len(v.Values) > 1 {
			for i, id := range v.Names {
				if id.Name == n.name {
					c.Values = []ast.Expr{v.Values[i]}
				}
			}
		}
		if tooLong(tp.fset, c.Values) {
			c.Values = nil
		}
		node = &ast.GenDecl{Tok: n.decl.Tok, Specs: []ast.Spec{&c}}
		idents = collectIdents(&c)
	case *ast.Field:
		return tp.fieldSignature(n, v)
	default:
		return &pb.Text{Text: n.name}
	}
	var buf bytes.Buffer
	cfg := printer.Config{Mode: printer.UseSpaces, Tabwidth: 4}
	if err := cfg.Fprint(&buf, tp.fset, node); err != nil {
		return &pb.Text{Text: n.name}
	}
	text := collapse(buf.String())
	switch n.node.(type) {
	case *ast.TypeSpec:
		if n.kind == pb.SymbolKind_STRUCT || n.kind == pb.SymbolKind_INTERFACE {
			text = emptyBody.ReplaceAllString(text, "$1")
		}
	case *ast.ValueSpec:
		v := n.node.(*ast.ValueSpec)
		switch {
		case len(v.Values) > 0 && !strings.Contains(text, " = "):
			text += " = …"
		case len(v.Values) == 0 && n.kind == pb.SymbolKind_CONST:
			// An implicit repetition in an iota group: show the value.
			if c, ok := n.obj.(*types.Const); ok && c.Val() != nil {
				text += " = " + c.Val().ExactString()
			}
		}
	}
	return tp.highlightPrinted(text, idents, n)
}

// fieldSignature renders a struct field ("Name Type", or "Type" when
// embedded) or an interface method ("Name(params) results").
func (tp *typedPackage) fieldSignature(n *declNode, f *ast.Field) *pb.Text {
	var buf bytes.Buffer
	cfg := printer.Config{Mode: printer.UseSpaces, Tabwidth: 4}
	if err := cfg.Fprint(&buf, tp.fset, f.Type); err != nil {
		return &pb.Text{Text: n.name}
	}
	typeText := collapse(buf.String())
	var text string
	var idents []*ast.Ident
	switch {
	case len(f.Names) == 0:
		text = typeText
	case n.kind == pb.SymbolKind_METHOD:
		text = n.name + strings.TrimPrefix(typeText, "func")
		idents = append(idents, findIdent(f.Names, n.name))
	default:
		text = n.name + " " + typeText
		idents = append(idents, findIdent(f.Names, n.name))
	}
	idents = append(idents, collectIdents(f.Type)...)
	return tp.highlightPrinted(text, idents, n)
}

func findIdent(ids []*ast.Ident, name string) *ast.Ident {
	for _, id := range ids {
		if id.Name == name {
			return id
		}
	}
	return ids[0]
}

// tooLong reports whether printing the values would not fit on one line.
func tooLong(fset *token.FileSet, values []ast.Expr) bool {
	for _, v := range values {
		start, end := fset.Position(v.Pos()), fset.Position(v.End())
		if start.Line != end.Line || end.Column-start.Column > 60 {
			return true
		}
		switch v.(type) {
		case *ast.CompositeLit, *ast.FuncLit:
			return true
		}
	}
	return false
}

func collectIdents(node ast.Node) []*ast.Ident {
	var ids []*ast.Ident
	ast.Inspect(node, func(n ast.Node) bool {
		if id, ok := n.(*ast.Ident); ok {
			ids = append(ids, id)
		}
		return true
	})
	return ids
}

var (
	trailingComma = regexp.MustCompile(`,\s*\n\s*([)\]}])`)
	newlines      = regexp.MustCompile(`\s*\n\s*`)
	emptyBody     = regexp.MustCompile(`(struct|interface)\s*\{\s*\}$`)
)

// collapse joins a multi-line printed node into one line.
func collapse(s string) string {
	s = trailingComma.ReplaceAllString(s, "$1")
	s = newlines.ReplaceAllString(s, " ")
	s = strings.ReplaceAll(s, "( ", "(")
	s = strings.ReplaceAll(s, " )", ")")
	return strings.TrimSpace(s)
}
