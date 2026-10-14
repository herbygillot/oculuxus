package analysis

import (
	"context"
	"fmt"
	"go/ast"
	"go/types"
	"strings"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// Hover describes the identifier at a position, or a declaration, for a
// hover card: its kind, signature, package, doc comment and location.
func (p *Project) Hover(ctx context.Context, req *pb.HoverRequest) (*pb.HoverResponse, error) {
	switch at := req.At.(type) {
	case *pb.HoverRequest_Symbol:
		if at.Symbol == nil || at.Symbol.PackageId == "" {
			return nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("hover: symbol needs a package id")}
		}
		if at.Symbol.DeclarationId == "" {
			h, err := p.packageHover(ctx, at.Symbol.PackageId, req.IncludeTests)
			return &pb.HoverResponse{Hover: h}, err
		}
		h, err := p.declarationHover(ctx, at.Symbol, req.IncludeTests)
		return &pb.HoverResponse{Hover: h}, err
	case *pb.HoverRequest_Position:
		if at.Position == nil || req.PackageId == "" {
			return nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("hover: position needs a package id and file")}
		}
		tp, err := p.Typed(ctx, req.PackageId, req.IncludeTests)
		if err != nil {
			return nil, err
		}
		id := tp.identAt(at.Position.File, at.Position.Offset)
		if id == nil {
			return &pb.HoverResponse{}, nil
		}
		obj := tp.objectOf(id)
		if obj == nil {
			return &pb.HoverResponse{}, nil
		}
		h, err := p.objectHover(ctx, tp, id, obj, req.IncludeTests)
		return &pb.HoverResponse{Hover: h}, err
	}
	return nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("hover: nothing to describe")}
}

// declarationHover describes a declaration from its outline entry.
func (p *Project) declarationHover(ctx context.Context, sym *pb.SymbolRef, tests bool) (*pb.Hover, error) {
	tp, err := p.Typed(ctx, sym.PackageId, tests)
	if err != nil {
		return nil, err
	}
	n, ok := tp.decls[sym.DeclarationId]
	if !ok {
		return nil, &Error{Code: pb.Error_NOT_FOUND, Err: fmt.Errorf("declaration %q not found in %s", sym.DeclarationId, sym.PackageId)}
	}
	return tp.hoverDecl(n), nil
}

func (tp *typedPackage) hoverDecl(n *declNode) *pb.Hover {
	h := &pb.Hover{
		Kind:        kindLabel(n),
		Name:        n.name,
		Signature:   tp.signature(n),
		PackageId:   tp.pkg.PkgPath,
		PackageName: tp.pkg.Name,
		Location:    tp.location(n.node.Pos()),
		Target:      &pb.SymbolRef{PackageId: tp.pkg.PkgPath, DeclarationId: n.id},
	}
	if n.doc != nil {
		h.Doc = docText(n.doc)
	}
	return h
}

// kindLabel names a declaration's kind for a hover card.
func kindLabel(n *declNode) string {
	switch n.kind {
	case pb.SymbolKind_CONST:
		return "const"
	case pb.SymbolKind_VAR:
		return "var"
	case pb.SymbolKind_FUNC:
		return "func"
	case pb.SymbolKind_METHOD:
		return "method"
	case pb.SymbolKind_STRUCT:
		return "struct"
	case pb.SymbolKind_INTERFACE:
		return "interface"
	case pb.SymbolKind_TYPE:
		return "type"
	case pb.SymbolKind_FIELD:
		if f, ok := n.node.(*ast.Field); ok && len(f.Names) == 0 {
			return "embedded field"
		}
		return "field"
	}
	return "declaration"
}

// packageHover describes an imported package: its name, path and doc.
func (p *Project) packageHover(ctx context.Context, pkgID string, tests bool) (*pb.Hover, error) {
	h := &pb.Hover{Kind: "package", PackageId: pkgID, Target: &pb.SymbolRef{PackageId: pkgID}}
	tp, err := p.Typed(ctx, pkgID, tests)
	if err != nil {
		if ctx.Err() != nil {
			return nil, err
		}
		h.Name = memberName(pkgID)
		h.Signature = plainText(fmt.Sprintf("package %s // %q", h.Name, pkgID))
		return h, nil
	}
	h.Name = tp.pkg.Name
	h.PackageName = tp.pkg.Name
	h.Signature = plainText(fmt.Sprintf("package %s // %q", tp.pkg.Name, pkgID))
	h.Doc = tp.packageDoc()
	if len(tp.pkg.Syntax) > 0 {
		h.Location = tp.location(tp.pkg.Syntax[0].Package)
	}
	return h, nil
}

// objectHover describes the object an identifier refers to. Navigable
// declarations get their outline signature and doc, from the package
// that declares them; everything else is described from its type.
func (p *Project) objectHover(ctx context.Context, tp *typedPackage, id *ast.Ident, obj types.Object, tests bool) (*pb.Hover, error) {
	qual := nameQualifier(tp.pkg.Types)
	switch o := obj.(type) {
	case *types.PkgName:
		return p.packageHover(ctx, o.Imported().Path(), tests)
	case *types.Label:
		return &pb.Hover{Kind: "label", Name: o.Name(), Signature: plainText(o.Name() + ":"), Location: tp.location(o.Pos())}, nil
	case *types.Builtin, *types.Nil:
		return &pb.Hover{Kind: "builtin", Name: o.Name(), Signature: plainText(types.ObjectString(o, qual))}, nil
	}
	if obj.Pkg() == nil {
		// Universe: int, error, true, iota, and the methods of error.
		return &pb.Hover{Kind: "builtin", Name: obj.Name(), Signature: plainText(types.ObjectString(obj, qual))}, nil
	}
	if tn, ok := obj.(*types.TypeName); ok {
		if _, ok := tn.Type().(*types.TypeParam); ok {
			return &pb.Hover{Kind: "type parameter", Name: tn.Name(), Signature: plainText(types.ObjectString(tn, qual)), Location: tp.location(tn.Pos())}, nil
		}
	}
	if ref := tp.refFor(id, obj); ref != nil && ref.DeclarationId != "" {
		var dtp *typedPackage
		if ref.PackageId == tp.pkg.PkgPath {
			dtp = tp
		} else if loaded, err := p.Typed(ctx, ref.PackageId, false); err == nil {
			dtp = loaded
		} else if ctx.Err() != nil {
			return nil, err
		}
		if dtp != nil {
			if n, ok := dtp.decls[ref.DeclarationId]; ok {
				return dtp.hoverDecl(n), nil
			}
		}
	}
	h := &pb.Hover{
		Name:      obj.Name(),
		Signature: plainText(types.ObjectString(obj, qual)),
	}
	if obj.Pos().IsValid() {
		h.Location = tp.location(obj.Pos())
	}
	if pkg := obj.Pkg(); pkg != nil {
		h.PackageId, h.PackageName = pkg.Path(), pkg.Name()
	}
	switch o := obj.(type) {
	case *types.Var:
		switch {
		case o.IsField():
			h.Kind = "field"
		case tp.isParam(o):
			h.Kind = "parameter"
		default:
			h.Kind = "local variable"
		}
	case *types.Const:
		h.Kind = "const"
	case *types.Func:
		h.Kind = "func"
		if sig, ok := o.Type().(*types.Signature); ok && sig.Recv() != nil {
			h.Kind = "method"
		}
	case *types.TypeName:
		h.Kind = "type"
	}
	return h, nil
}

// docText returns a doc comment as plain text.
func docText(cg *ast.CommentGroup) string {
	if cg == nil {
		return ""
	}
	return strings.TrimSpace(cg.Text())
}

// plainText highlights text lexically: keywords, strings, numbers and
// operators, with identifiers left plain.
func plainText(text string) *pb.Text {
	out := &pb.Text{Text: text}
	for _, l := range scanText([]byte(text)) {
		if t, ok := lexicalType(l); ok {
			out.Tokens = append(out.Tokens, &pb.Token{Range: &pb.Range{Start: l.start, End: l.end}, Type: t})
		}
	}
	return out
}
