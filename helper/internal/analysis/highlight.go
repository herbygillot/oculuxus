package analysis

import (
	"go/ast"
	"go/scanner"
	"go/token"
	"go/types"
	"sort"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// lexeme is one lexical token in some text.
type lexeme struct {
	start, end uint32
	tok        token.Token
	lit        string
}

// scanText tokenizes src with go/scanner. Automatic semicolons are dropped.
func scanText(src []byte) []lexeme {
	fset := token.NewFileSet()
	file := fset.AddFile("", -1, len(src))
	var s scanner.Scanner
	s.Init(file, src, nil, scanner.ScanComments)
	var out []lexeme
	for {
		pos, tok, lit := s.Scan()
		if tok == token.EOF {
			break
		}
		if tok == token.SEMICOLON && lit == "\n" {
			continue
		}
		start := uint32(file.Offset(pos))
		length := len(lit)
		if length == 0 || tok.IsOperator() || tok.IsKeyword() {
			length = len(tok.String())
			if tok == token.SEMICOLON {
				length = 1
			}
		}
		out = append(out, lexeme{start: start, end: start + uint32(length), tok: tok, lit: lit})
	}
	return out
}

// lexicalType classifies a non-identifier token.
func lexicalType(l lexeme) (pb.TokenType, bool) {
	switch {
	case l.tok == token.COMMENT:
		return pb.TokenType_COMMENT, true
	case l.tok == token.STRING || l.tok == token.CHAR:
		return pb.TokenType_STRING, true
	case l.tok == token.INT || l.tok == token.FLOAT || l.tok == token.IMAG:
		return pb.TokenType_NUMBER, true
	case l.tok.IsKeyword():
		return pb.TokenType_KEYWORD, true
	case l.tok.IsOperator():
		return pb.TokenType_OPERATOR, true
	}
	return pb.TokenType_TOKEN_TYPE_UNSPECIFIED, false
}

// identToken classifies an identifier through its type-checker object.
func (tp *typedPackage) identToken(id *ast.Ident) (pb.TokenType, uint32, *pb.SymbolRef) {
	info := tp.pkg.TypesInfo
	var mods uint32
	obj := info.Uses[id]
	if obj == nil {
		obj = info.Defs[id]
		if obj != nil {
			mods |= uint32(pb.TokenModifier_DEFINITION)
		}
	}
	if obj == nil {
		if id.Name == "_" {
			return pb.TokenType_VARIABLE, 0, nil
		}
		return pb.TokenType_TOKEN_TYPE_UNSPECIFIED, 0, nil
	}
	if obj.Exported() {
		mods |= uint32(pb.TokenModifier_EXPORTED)
	}
	var ref *pb.SymbolRef
	switch o := obj.(type) {
	case *types.PkgName:
		return pb.TokenType_NAMESPACE, mods, objectRef(o)
	case *types.Builtin, *types.Nil:
		return pb.TokenType_BUILTIN, mods, nil
	case *types.Label:
		return pb.TokenType_LABEL, mods, nil
	case *types.Const:
		if o.Pkg() == nil {
			return pb.TokenType_BUILTIN, mods, nil // true, false, iota
		}
		return pb.TokenType_CONSTANT, mods, objectRef(o)
	case *types.TypeName:
		if o.Pkg() == nil {
			return pb.TokenType_BUILTIN, mods, nil // int, error, any ...
		}
		if _, ok := o.Type().(*types.TypeParam); ok {
			return pb.TokenType_TYPE_PARAMETER, mods, nil
		}
		ref = objectRef(o)
		switch types.Unalias(o.Type()).Underlying().(type) {
		case *types.Struct:
			return pb.TokenType_STRUCT_NAME, mods, ref
		case *types.Interface:
			return pb.TokenType_INTERFACE_NAME, mods, ref
		}
		return pb.TokenType_TYPE_NAME, mods, ref
	case *types.Func:
		if sig, ok := o.Type().(*types.Signature); ok && sig.Recv() != nil {
			return pb.TokenType_METHOD_NAME, mods, objectRef(o)
		}
		return pb.TokenType_FUNCTION, mods, objectRef(o)
	case *types.Var:
		if o.IsField() {
			return pb.TokenType_PROPERTY, mods, tp.fieldRefFor(id, o)
		}
		if tp.isParam(o) {
			return pb.TokenType_PARAMETER, mods, nil
		}
		return pb.TokenType_VARIABLE, mods, objectRef(o)
	}
	return pb.TokenType_TOKEN_TYPE_UNSPECIFIED, mods, nil
}

// fieldRefFor finds the struct that declares the field an identifier
// refers to.
func (tp *typedPackage) fieldRefFor(id *ast.Ident, v *types.Var) *pb.SymbolRef {
	if declID, ok := tp.byObj[v]; ok {
		return &pb.SymbolRef{PackageId: tp.pkg.PkgPath, DeclarationId: declID}
	}
	// A selector x.f: the selection carries the receiver type.
	if sel, ok := tp.selections[id]; ok {
		return fieldRef(sel)
	}
	// A composite literal key, T{f: v}: find the struct that declares f.
	tp.fieldsMu.Lock()
	defer tp.fieldsMu.Unlock()
	if tp.fields == nil {
		tp.fields = newFieldOwners()
	}
	return tp.fields.ref(v)
}

func (tp *typedPackage) isParam(v *types.Var) bool {
	// Parameters and results live in a function scope but are declared in
	// the signature; go/types gives them no distinct kind. A variable whose
	// parent scope is the function's own scope and whose position lies
	// before the body is a parameter.
	// Parameters and results are declared in the function scope, which
	// top-level locals of the body share; position tells them apart.
	ft := tp.paramScopes[v.Parent()]
	return ft != nil && v.Pos() < ft.End()
}

// highlightPrinted matches identifiers in a printed signature to the
// syntax identifiers it was printed from.
func (tp *typedPackage) highlightPrinted(text string, idents []*ast.Ident, n *declNode) *pb.Text {
	out := &pb.Text{Text: text}
	lexemes := scanText([]byte(text))
	var identLexemes int
	for _, l := range lexemes {
		if l.tok == token.IDENT {
			identLexemes++
		}
	}
	match := identLexemes == len(idents)
	i := 0
	for _, l := range lexemes {
		tok := &pb.Token{Range: &pb.Range{Start: l.start, End: l.end}}
		if l.tok == token.IDENT {
			if match {
				tok.Type, tok.Modifiers, tok.Target = tp.identToken(idents[i])
				i++
			}
			if tok.Type == pb.TokenType_TOKEN_TYPE_UNSPECIFIED {
				continue
			}
		} else if t, ok := lexicalType(l); ok {
			tok.Type = t
		} else {
			continue
		}
		out.Tokens = append(out.Tokens, tok)
	}
	return out
}

// highlightSource highlights a slice of a file's source. start is the
// slice's byte offset in the file.
func (tp *typedPackage) highlightSource(file *ast.File, src []byte, start uint32) *pb.Text {
	out := &pb.Text{Text: string(src)}
	tf := tp.fset.File(file.Pos())
	base := uint32(tf.Base())
	// Identifiers by file offset, so lexemes can find their syntax node.
	idents := map[uint32]*ast.Ident{}
	ast.Inspect(file, func(n ast.Node) bool {
		if id, ok := n.(*ast.Ident); ok {
			idents[uint32(id.Pos())-base] = id
		}
		return true
	})
	docRanges := tp.docRanges(file, base)
	for _, l := range scanText(src) {
		tok := &pb.Token{Range: &pb.Range{Start: l.start, End: l.end}}
		if l.tok == token.IDENT {
			id := idents[start+l.start]
			if id == nil {
				continue
			}
			tok.Type, tok.Modifiers, tok.Target = tp.identToken(id)
			if tok.Type == pb.TokenType_TOKEN_TYPE_UNSPECIFIED {
				continue
			}
		} else if t, ok := lexicalType(l); ok {
			tok.Type = t
			if t == pb.TokenType_COMMENT && docRanges[start+l.start] {
				tok.Modifiers |= uint32(pb.TokenModifier_DOCUMENTATION)
			}
		} else {
			continue
		}
		out.Tokens = append(out.Tokens, tok)
	}
	sort.Slice(out.Tokens, func(i, j int) bool { return out.Tokens[i].Range.Start < out.Tokens[j].Range.Start })
	return out
}

// docRanges returns the file offsets of every comment that is a doc
// comment of a declaration, member, or the package.
func (tp *typedPackage) docRanges(file *ast.File, base uint32) map[uint32]bool {
	out := map[uint32]bool{}
	add := func(cg *ast.CommentGroup) {
		if cg == nil {
			return
		}
		for _, c := range cg.List {
			out[uint32(c.Pos())-base] = true
		}
	}
	add(file.Doc)
	ast.Inspect(file, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.FuncDecl:
			add(n.Doc)
		case *ast.GenDecl:
			add(n.Doc)
		case *ast.TypeSpec:
			add(n.Doc)
		case *ast.ValueSpec:
			add(n.Doc)
		case *ast.Field:
			add(n.Doc)
		}
		return true
	})
	return out
}
