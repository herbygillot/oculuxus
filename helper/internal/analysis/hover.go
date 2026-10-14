package analysis

import (
	"context"
	"fmt"
	"go/ast"
	"go/token"
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
	switch o := obj.(type) {
	case *types.PkgName:
		return p.packageHover(ctx, o.Imported().Path(), tests)
	case *types.Label:
		return &pb.Hover{Kind: "label", Name: o.Name(), Signature: plainText(o.Name() + ":"), Location: tp.location(o.Pos())}, nil
	case *types.Builtin, *types.Nil:
		return &pb.Hover{Kind: "builtin", Name: o.Name(), Signature: tp.objectText(o)}, nil
	}
	if obj.Pkg() == nil {
		// Universe: int, error, true, iota, and the methods of error.
		return &pb.Hover{Kind: "builtin", Name: obj.Name(), Signature: tp.objectText(obj)}, nil
	}
	if tn, ok := obj.(*types.TypeName); ok {
		if _, ok := tn.Type().(*types.TypeParam); ok {
			return &pb.Hover{Kind: "type parameter", Name: tn.Name(), Signature: tp.objectText(tn), Location: tp.location(tn.Pos())}, nil
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
		Signature: tp.objectText(obj),
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

// objectText renders an object as go/types prints it, with the object's
// name and the type names in its type highlighted and linked. Types from
// other packages are qualified by package name, so a qualified name in
// the text is looked up as "pkg.Name" and a bare one as a local or
// universe name.
func (tp *typedPackage) objectText(obj types.Object) *pb.Text {
	qual := nameQualifier(tp.pkg.Types)
	text := types.ObjectString(obj, qual)
	out := &pb.Text{Text: text}
	names := map[string]*types.TypeName{}
	collectTypeNames(obj.Type(), names, qual, map[types.Type]bool{})
	lexemes := scanText([]byte(text))
	nameType, nameMods := objectTokenType(tp, obj)
	named := false
	for i := 0; i < len(lexemes); i++ {
		l := lexemes[i]
		tok := &pb.Token{Range: &pb.Range{Start: l.start, End: l.end}}
		if l.tok != token.IDENT {
			if t, ok := lexicalType(l); ok {
				tok.Type = t
				out.Tokens = append(out.Tokens, tok)
			}
			continue
		}
		if !named && l.lit == obj.Name() {
			// The declared name: the first identifier after the keyword.
			named = true
			if nameType != pb.TokenType_TOKEN_TYPE_UNSPECIFIED {
				tok.Type, tok.Modifiers = nameType, nameMods|uint32(pb.TokenModifier_DEFINITION)
				out.Tokens = append(out.Tokens, tok)
			}
			continue
		}
		// pkg.Name: a qualified type name from another package.
		if i+2 < len(lexemes) && lexemes[i+1].tok == token.PERIOD && lexemes[i+2].tok == token.IDENT {
			if tn, ok := names[l.lit+"."+lexemes[i+2].lit]; ok {
				tok.Type = pb.TokenType_NAMESPACE
				tok.Target = &pb.SymbolRef{PackageId: tn.Pkg().Path()}
				out.Tokens = append(out.Tokens, tok)
				out.Tokens = append(out.Tokens, &pb.Token{Range: &pb.Range{Start: lexemes[i+1].start, End: lexemes[i+1].end}, Type: pb.TokenType_OPERATOR})
				nt := &pb.Token{Range: &pb.Range{Start: lexemes[i+2].start, End: lexemes[i+2].end}}
				nt.Type, nt.Modifiers, nt.Target = typeNameToken(tn)
				out.Tokens = append(out.Tokens, nt)
				i += 2
				continue
			}
		}
		if tn, ok := names[l.lit]; ok {
			tok.Type, tok.Modifiers, tok.Target = typeNameToken(tn)
			out.Tokens = append(out.Tokens, tok)
		}
	}
	return out
}

// objectTokenType classifies the declared name in an object's text.
func objectTokenType(tp *typedPackage, obj types.Object) (pb.TokenType, uint32) {
	var mods uint32
	if obj.Exported() {
		mods |= uint32(pb.TokenModifier_EXPORTED)
	}
	switch o := obj.(type) {
	case *types.Var:
		switch {
		case o.IsField():
			return pb.TokenType_PROPERTY, mods
		case tp.isParam(o):
			return pb.TokenType_PARAMETER, mods
		}
		return pb.TokenType_VARIABLE, mods
	case *types.Const:
		if o.Pkg() == nil {
			return pb.TokenType_BUILTIN, mods
		}
		return pb.TokenType_CONSTANT, mods
	case *types.Func:
		if sig, ok := o.Type().(*types.Signature); ok && sig.Recv() != nil {
			return pb.TokenType_METHOD_NAME, mods
		}
		return pb.TokenType_FUNCTION, mods
	case *types.TypeName:
		t, m, _ := typeNameToken(o)
		return t, m
	case *types.Builtin, *types.Nil:
		return pb.TokenType_BUILTIN, mods
	}
	return pb.TokenType_TOKEN_TYPE_UNSPECIFIED, mods
}

// typeNameToken classifies a type name and links it to its declaration.
func typeNameToken(tn *types.TypeName) (pb.TokenType, uint32, *pb.SymbolRef) {
	var mods uint32
	if tn.Exported() {
		mods |= uint32(pb.TokenModifier_EXPORTED)
	}
	if tn.Pkg() == nil {
		return pb.TokenType_BUILTIN, mods, nil
	}
	if _, ok := tn.Type().(*types.TypeParam); ok {
		return pb.TokenType_TYPE_PARAMETER, mods, nil
	}
	ref := objectRef(tn)
	switch types.Unalias(tn.Type()).Underlying().(type) {
	case *types.Struct:
		return pb.TokenType_STRUCT_NAME, mods, ref
	case *types.Interface:
		return pb.TokenType_INTERFACE_NAME, mods, ref
	}
	return pb.TokenType_TYPE_NAME, mods, ref
}

// collectTypeNames records the type names a type string mentions, keyed
// as the qualifier prints them.
func collectTypeNames(t types.Type, out map[string]*types.TypeName, qual types.Qualifier, seen map[types.Type]bool) {
	if t == nil || seen[t] {
		return
	}
	seen[t] = true
	add := func(tn *types.TypeName) {
		key := tn.Name()
		if tn.Pkg() != nil {
			if q := qual(tn.Pkg()); q != "" {
				key = q + "." + key
			}
		}
		out[key] = tn
	}
	switch t := t.(type) {
	case *types.Named:
		add(t.Obj())
		for i := 0; i < t.TypeArgs().Len(); i++ {
			collectTypeNames(t.TypeArgs().At(i), out, qual, seen)
		}
	case *types.Alias:
		add(t.Obj())
		for i := 0; i < t.TypeArgs().Len(); i++ {
			collectTypeNames(t.TypeArgs().At(i), out, qual, seen)
		}
	case *types.TypeParam:
		add(t.Obj())
	case *types.Basic:
		if tn, ok := types.Universe.Lookup(t.Name()).(*types.TypeName); ok {
			add(tn)
		}
	case *types.Pointer:
		collectTypeNames(t.Elem(), out, qual, seen)
	case *types.Slice:
		collectTypeNames(t.Elem(), out, qual, seen)
	case *types.Array:
		collectTypeNames(t.Elem(), out, qual, seen)
	case *types.Chan:
		collectTypeNames(t.Elem(), out, qual, seen)
	case *types.Map:
		collectTypeNames(t.Key(), out, qual, seen)
		collectTypeNames(t.Elem(), out, qual, seen)
	case *types.Struct:
		for i := 0; i < t.NumFields(); i++ {
			collectTypeNames(t.Field(i).Type(), out, qual, seen)
		}
	case *types.Tuple:
		for i := 0; i < t.Len(); i++ {
			collectTypeNames(t.At(i).Type(), out, qual, seen)
		}
	case *types.Signature:
		collectTypeNames(t.Params(), out, qual, seen)
		collectTypeNames(t.Results(), out, qual, seen)
		if t.Recv() != nil {
			collectTypeNames(t.Recv().Type(), out, qual, seen)
		}
		for i := 0; i < t.TypeParams().Len(); i++ {
			tp := t.TypeParams().At(i)
			add(tp.Obj())
			collectTypeNames(tp.Constraint(), out, qual, seen)
		}
	case *types.Interface:
		for i := 0; i < t.NumExplicitMethods(); i++ {
			collectTypeNames(t.ExplicitMethod(i).Type(), out, qual, seen)
		}
		for i := 0; i < t.NumEmbeddeds(); i++ {
			collectTypeNames(t.EmbeddedType(i), out, qual, seen)
		}
	case *types.Union:
		for i := 0; i < t.Len(); i++ {
			collectTypeNames(t.Term(i).Type(), out, qual, seen)
		}
	}
}
