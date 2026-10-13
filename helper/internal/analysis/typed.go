package analysis

import (
	"context"
	"fmt"
	"go/ast"
	"go/token"
	"go/types"
	"os"
	"sort"
	"strings"
	"sync"

	"golang.org/x/tools/go/packages"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

const typedMode = packages.NeedName | packages.NeedFiles | packages.NeedCompiledGoFiles |
	packages.NeedImports | packages.NeedModule | packages.NeedTypes | packages.NeedSyntax |
	packages.NeedTypesInfo

// typedPackage is one package parsed and type-checked, with the index the
// outline and source requests need.
type typedPackage struct {
	pkg     *packages.Package
	fset    *token.FileSet
	sources map[string][]byte // file path -> contents
	deps    map[string]bool   // transitive import paths
	xtest   string            // with tests: the external test package, if any

	// Declarations by id ("Name", "Type.Member"), and the objects they
	// declare, for resolving references.
	decls   map[string]*declNode
	byObj   map[types.Object]string // object -> declaration id
	outline *pb.PackageOutline
	roots   []*declNode

	selections  map[*ast.Ident]*types.Selection // selector identifiers
	paramScopes map[*types.Scope]*ast.FuncType  // function scopes by signature
}

// declNode is a declaration found in the syntax.
type declNode struct {
	id      string
	kind    pb.SymbolKind
	name    string
	file    *ast.File
	path    string
	node    ast.Node // *ast.FuncDecl, *ast.TypeSpec, *ast.ValueSpec, *ast.Field
	decl    *ast.GenDecl
	doc     *ast.CommentGroup
	obj     types.Object
	members []*declNode
}

func (tp *typedPackage) dependsOn(paths map[string]bool) bool {
	for p := range paths {
		if tp.deps[p] {
			return true
		}
	}
	return false
}

// Typed returns the type-checked package with the given import path,
// loading it on first use. Concurrent requests for the same package share
// one load. With tests, the package includes its _test.go files; an
// external test package ("pkg_test") is only available with tests.
func (p *Project) Typed(ctx context.Context, importPath string, tests bool) (*typedPackage, error) {
	key := typedKey(importPath, tests)
	for {
		p.mu.Lock()
		if tp, ok := p.typed[key]; ok {
			p.mu.Unlock()
			return tp, nil
		}
		if wg, ok := p.inflight[key]; ok {
			p.mu.Unlock()
			wg.Wait()
			continue
		}
		wg := &sync.WaitGroup{}
		wg.Add(1)
		p.inflight[key] = wg
		p.mu.Unlock()

		tp, err := p.loadTyped(ctx, importPath, tests)

		p.mu.Lock()
		delete(p.inflight, key)
		if err == nil {
			p.typed[key] = tp
		}
		p.mu.Unlock()
		wg.Done()
		return tp, err
	}
}

func typedKey(importPath string, tests bool) string {
	if tests {
		return importPath + " [tests]"
	}
	return importPath
}

func (p *Project) loadTyped(ctx context.Context, importPath string, tests bool) (*typedPackage, error) {
	if importPath == "" {
		return nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("empty package id")}
	}
	pattern := importPath
	if tests {
		// An external test package is loaded through the package it tests.
		if base, ok := strings.CutSuffix(importPath, "_test"); ok && !p.listed(importPath) {
			pattern = base
		}
	}
	cfg := p.config(ctx, typedMode)
	cfg.Tests = tests
	pkgs, err := packages.Load(cfg, pattern)
	if err != nil {
		return nil, &Error{Code: pb.Error_LOAD_FAILED, Err: err}
	}
	pkg := pickPackage(pkgs, importPath, tests)
	if pkg == nil || (len(pkg.CompiledGoFiles) == 0 && len(pkg.Errors) > 0) {
		// go list reports a missing package as one with an error and no files.
		return nil, &Error{Code: pb.Error_NOT_FOUND, Err: fmt.Errorf("package %q not found", importPath)}
	}
	if pkg.Types == nil || pkg.TypesInfo == nil {
		return nil, &Error{Code: pb.Error_LOAD_FAILED, Err: fmt.Errorf("package %q: %s", importPath, firstError(pkg))}
	}
	tp := &typedPackage{
		pkg:     pkg,
		fset:    pkg.Fset,
		sources: map[string][]byte{},
		deps:    map[string]bool{},
		decls:   map[string]*declNode{},
		byObj:   map[types.Object]string{},
	}
	if tests {
		for _, c := range pkgs {
			if c.PkgPath == importPath+"_test" {
				tp.xtest = c.PkgPath
			}
		}
	}
	for _, f := range pkg.CompiledGoFiles {
		src, err := os.ReadFile(f)
		if err != nil {
			return nil, &Error{Code: pb.Error_LOAD_FAILED, Err: err}
		}
		tp.sources[f] = src
	}
	packages.Visit([]*packages.Package{pkg}, nil, func(d *packages.Package) {
		if d != pkg {
			tp.deps[d.PkgPath] = true
		}
	})
	tp.selections = map[*ast.Ident]*types.Selection{}
	for sel, s := range pkg.TypesInfo.Selections {
		tp.selections[sel.Sel] = s
	}
	tp.paramScopes = map[*types.Scope]*ast.FuncType{}
	for node, scope := range pkg.TypesInfo.Scopes {
		if ft, ok := node.(*ast.FuncType); ok {
			tp.paramScopes[scope] = ft
		}
	}
	tp.index()
	tp.outline = tp.buildOutline()
	return tp, nil
}

// pickPackage finds importPath among loaded packages. With tests it
// prefers the test build of the package ("p [p.test]"), which includes the
// package's own _test.go files.
func pickPackage(pkgs []*packages.Package, importPath string, tests bool) *packages.Package {
	var plain, test *packages.Package
	for _, c := range pkgs {
		if c.PkgPath != importPath || strings.HasSuffix(c.ID, ".test") {
			continue
		}
		if isTestVariant(c) {
			if strings.HasSuffix(c.ID, "["+strings.TrimSuffix(importPath, "_test")+".test]") {
				test = c
			}
		} else {
			plain = c
		}
	}
	if tests && test != nil {
		return test
	}
	return plain
}

// listed reports whether importPath is in the package list.
func (p *Project) listed(importPath string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, ok := p.meta[importPath]
	return ok
}

func firstError(pkg *packages.Package) string {
	if len(pkg.Errors) > 0 {
		return pkg.Errors[0].Error()
	}
	return "no type information"
}

// index records every declaration and its members, in source order.
func (tp *typedPackage) index() {
	tp.roots = declTree(tp.fset, tp.pkg.Syntax, tp.pkg.TypesInfo)
	for _, n := range tp.roots {
		tp.record(n)
	}
}

// declTree walks the syntax and returns every top-level declaration, with
// methods nested under their receiver types and fields and interface
// methods under their types. info may be nil when only syntax is loaded;
// the nodes then carry no objects. The symbol index and the outline both
// use it, so declaration ids agree between the two.
func declTree(fset *token.FileSet, files []*ast.File, info *types.Info) []*declNode {
	var types_ []*declNode
	var top []*declNode
	for _, file := range files {
		path := fset.File(file.Pos()).Name()
		for _, d := range file.Decls {
			switch d := d.(type) {
			case *ast.FuncDecl:
				n := &declNode{name: d.Name.Name, file: file, path: path, node: d, doc: d.Doc, obj: defOf(info, d.Name)}
				if d.Recv != nil {
					n.kind = pb.SymbolKind_METHOD
				} else {
					n.kind = pb.SymbolKind_FUNC
				}
				top = append(top, n)
			case *ast.GenDecl:
				for _, spec := range d.Specs {
					switch s := spec.(type) {
					case *ast.TypeSpec:
						n := &declNode{name: s.Name.Name, file: file, path: path, node: s, decl: d, doc: specDoc(s.Doc, d), obj: defOf(info, s.Name)}
						switch s.Type.(type) {
						case *ast.StructType:
							n.kind = pb.SymbolKind_STRUCT
						case *ast.InterfaceType:
							n.kind = pb.SymbolKind_INTERFACE
						default:
							n.kind = pb.SymbolKind_TYPE
						}
						n.id = n.name
						addMembers(info, n, s)
						top = append(top, n)
						types_ = append(types_, n)
					case *ast.ValueSpec:
						kind := pb.SymbolKind_VAR
						if d.Tok == token.CONST {
							kind = pb.SymbolKind_CONST
						}
						for _, name := range s.Names {
							if name.Name == "_" {
								continue
							}
							n := &declNode{name: name.Name, kind: kind, file: file, path: path, node: s, decl: d, doc: specDoc(s.Doc, d), obj: defOf(info, name)}
							top = append(top, n)
						}
					}
				}
			}
		}
	}
	// Attach methods to their receiver types.
	byName := map[string]*declNode{}
	for _, t := range types_ {
		byName[t.name] = t
	}
	var roots []*declNode
	for _, n := range top {
		if n.kind == pb.SymbolKind_METHOD {
			recv := receiverTypeName(n.node.(*ast.FuncDecl))
			if t, ok := byName[recv]; ok {
				n.id = t.name + "." + n.name
				t.members = append(t.members, n)
				continue
			}
		}
		if n.id == "" {
			n.id = n.name
		}
		roots = append(roots, n)
	}
	// Members: fields and interface methods in declaration order, then
	// methods by file name and position (files may be parsed in any order,
	// so token.Pos alone does not give source order across files).
	for _, t := range types_ {
		sort.SliceStable(t.members, func(i, j int) bool {
			a, b := t.members[i], t.members[j]
			if isFuncDecl(a) != isFuncDecl(b) {
				return !isFuncDecl(a)
			}
			if !isFuncDecl(a) {
				return false // keep declaration order
			}
			if a.path != b.path {
				return a.path < b.path
			}
			return a.node.Pos() < b.node.Pos()
		})
	}
	return roots
}

func defOf(info *types.Info, id *ast.Ident) types.Object {
	if info == nil {
		return nil
	}
	return info.Defs[id]
}

func isFuncDecl(n *declNode) bool {
	_, ok := n.node.(*ast.FuncDecl)
	return ok
}

func (tp *typedPackage) record(n *declNode) {
	if _, dup := tp.decls[n.id]; dup {
		// Duplicate names only happen in broken code; keep the first.
		return
	}
	tp.decls[n.id] = n
	if n.obj != nil {
		tp.byObj[n.obj] = n.id
	}
	for _, m := range n.members {
		tp.record(m)
	}
}

// addMembers records struct fields and interface methods as members.
func addMembers(info *types.Info, t *declNode, spec *ast.TypeSpec) {
	switch st := spec.Type.(type) {
	case *ast.StructType:
		for _, f := range st.Fields.List {
			if len(f.Names) == 0 {
				name := embeddedName(f.Type)
				t.members = append(t.members, &declNode{
					id: t.name + "." + name, name: name, kind: pb.SymbolKind_FIELD,
					file: t.file, path: t.path, node: f, doc: f.Doc, obj: fieldObj(info, f),
				})
				continue
			}
			for _, name := range f.Names {
				t.members = append(t.members, &declNode{
					id: t.name + "." + name.Name, name: name.Name, kind: pb.SymbolKind_FIELD,
					file: t.file, path: t.path, node: f, doc: f.Doc, obj: defOf(info, name),
				})
			}
		}
	case *ast.InterfaceType:
		for _, f := range st.Methods.List {
			if len(f.Names) == 0 {
				name := embeddedName(f.Type)
				t.members = append(t.members, &declNode{
					id: t.name + "." + name, name: name, kind: pb.SymbolKind_FIELD,
					file: t.file, path: t.path, node: f, doc: f.Doc,
				})
				continue
			}
			for _, name := range f.Names {
				t.members = append(t.members, &declNode{
					id: t.name + "." + name.Name, name: name.Name, kind: pb.SymbolKind_METHOD,
					file: t.file, path: t.path, node: f, doc: f.Doc, obj: defOf(info, name),
				})
			}
		}
	}
}

func fieldObj(info *types.Info, f *ast.Field) types.Object {
	// An embedded field's object is defined on its type's identifier.
	if id := typeIdent(f.Type); id != nil {
		if obj := defOf(info, id); obj != nil {
			return obj
		}
	}
	return nil
}

// typeIdent returns the identifier at the heart of an embedded field type
// such as T, *T, pkg.T, or T[int].
func typeIdent(e ast.Expr) *ast.Ident {
	switch e := e.(type) {
	case *ast.Ident:
		return e
	case *ast.StarExpr:
		return typeIdent(e.X)
	case *ast.SelectorExpr:
		return e.Sel
	case *ast.IndexExpr:
		return typeIdent(e.X)
	case *ast.IndexListExpr:
		return typeIdent(e.X)
	}
	return nil
}

func embeddedName(e ast.Expr) string {
	if id := typeIdent(e); id != nil {
		return id.Name
	}
	return "?"
}

func receiverTypeName(d *ast.FuncDecl) string {
	if d.Recv == nil || len(d.Recv.List) == 0 {
		return ""
	}
	if id := typeIdent(d.Recv.List[0].Type); id != nil {
		return id.Name
	}
	return ""
}

func specDoc(doc *ast.CommentGroup, d *ast.GenDecl) *ast.CommentGroup {
	if doc != nil {
		return doc
	}
	if len(d.Specs) == 1 {
		return d.Doc
	}
	return nil
}

// objectRef resolves an object to the declaration the app can navigate to.
func objectRef(obj types.Object) *pb.SymbolRef {
	if obj == nil {
		return nil
	}
	switch o := obj.(type) {
	case *types.PkgName:
		return &pb.SymbolRef{PackageId: o.Imported().Path()}
	case *types.Builtin, *types.Nil, *types.Label:
		return nil
	}
	pkg := obj.Pkg()
	if pkg == nil {
		return nil // universe: error.Error and friends
	}
	if obj.Parent() == pkg.Scope() {
		return &pb.SymbolRef{PackageId: pkg.Path(), DeclarationId: obj.Name()}
	}
	switch o := obj.(type) {
	case *types.Func:
		sig, _ := o.Type().(*types.Signature)
		if sig == nil || sig.Recv() == nil {
			return nil
		}
		if named := namedOf(sig.Recv().Type()); named != nil && named.Obj().Pkg() != nil {
			return &pb.SymbolRef{PackageId: named.Obj().Pkg().Path(), DeclarationId: named.Obj().Name() + "." + o.Name()}
		}
	case *types.TypeName:
		// Type parameters and local types have no navigable declaration.
		return nil
	}
	return nil
}

// fieldRef resolves a selected field to "Struct.Field" by walking the
// selection's index path to the struct that declares it.
func fieldRef(sel *types.Selection) *pb.SymbolRef {
	if sel == nil || sel.Kind() != types.FieldVal {
		return nil
	}
	t := sel.Recv()
	idx := sel.Index()
	var owner *types.Named
	for i, fi := range idx {
		named := namedOf(t)
		st, ok := namedOf(t).Underlying().(*types.Struct)
		if named == nil || !ok {
			st, ok = derefType(t).Underlying().(*types.Struct)
			if !ok {
				return nil
			}
			named = nil
		}
		if fi >= st.NumFields() {
			return nil
		}
		f := st.Field(fi)
		if i == len(idx)-1 {
			owner = named
			if owner == nil || owner.Obj().Pkg() == nil {
				return nil
			}
			return &pb.SymbolRef{PackageId: owner.Obj().Pkg().Path(), DeclarationId: owner.Obj().Name() + "." + f.Name()}
		}
		t = f.Type()
	}
	return nil
}

func derefType(t types.Type) types.Type {
	if p, ok := t.(*types.Pointer); ok {
		return p.Elem()
	}
	return t
}

func namedOf(t types.Type) *types.Named {
	switch t := derefType(t).(type) {
	case *types.Named:
		return t
	case *types.Alias:
		return namedOf(types.Unalias(t))
	}
	return nil
}

func exported(name string) bool {
	return token.IsExported(name)
}

func fileName(path string) string {
	if i := strings.LastIndexAny(path, `/\`); i >= 0 {
		return path[i+1:]
	}
	return path
}
