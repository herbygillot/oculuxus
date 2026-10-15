package analysis

import (
	"go/ast"
	"go/token"
	"go/types"
	"sort"

	"golang.org/x/tools/go/packages"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// pkgRefs holds every reference one package makes to navigable
// declarations, recorded from go/types once the package is type-checked.
// Sites are grouped by the declaration they refer to.
type pkgRefs struct {
	fingerprint []byte
	files       []string
	byTarget    map[refKey][]refSite
	// Interface methods referenced, by method name: the targets a
	// "via interface" lookup for a concrete method has to consider.
	abstract map[string][]refKey
}

// refKey identifies a declaration: a package id and a declaration id.
type refKey struct {
	pkg, decl string
}

// refSite is one use of a declaration.
type refSite struct {
	file      uint32 // index into pkgRefs.files
	line, col uint32
	length    uint32
	call      bool
	abstract  bool   // the target is an interface method
	enclosing string // the declaration containing the use, "" for none
}

// extractRefs records the references in a type-checked package. Every
// identifier that go/types resolves to a declaration the app can
// navigate to becomes a site; local variables and package names do not.
func extractRefs(pkg *packages.Package, fp []byte) *pkgRefs {
	r := &pkgRefs{fingerprint: fp, byTarget: map[refKey][]refSite{}, abstract: map[string][]refKey{}}
	fset := pkg.Fset
	info := pkg.TypesInfo
	fileIndex := map[string]uint32{}
	fileOf := func(path string) uint32 {
		fi, ok := fileIndex[path]
		if !ok {
			fi = uint32(len(r.files))
			fileIndex[path] = fi
			r.files = append(r.files, path)
		}
		return fi
	}
	selections := map[*ast.Ident]*types.Selection{}
	for sel, s := range info.Selections {
		selections[sel.Sel] = s
	}
	fields := newFieldOwners()
	spans := declSpans(fset, pkg.Syntax, info)
	called := calledIdents(pkg.Syntax)
	seenAbstract := map[refKey]bool{}

	for id, obj := range info.Uses {
		if obj == nil {
			continue
		}
		var ref *pb.SymbolRef
		if v, ok := obj.(*types.Var); ok && v.IsField() {
			if sel, ok := selections[id]; ok {
				ref = fieldRef(sel)
			} else {
				ref = fields.ref(v)
			}
		} else {
			ref = objectRef(obj)
		}
		if ref == nil || ref.DeclarationId == "" {
			continue
		}
		key := refKey{pkg: ref.PackageId, decl: ref.DeclarationId}
		pos := fset.Position(id.Pos())
		site := refSite{
			file:      fileOf(pos.Filename),
			line:      uint32(pos.Line),
			col:       uint32(pos.Column),
			length:    uint32(len(id.Name)),
			call:      called[id],
			abstract:  isAbstractMethod(obj),
			enclosing: spans.enclosing(pos.Filename, id.Pos()),
		}
		r.byTarget[key] = append(r.byTarget[key], site)
		if site.abstract && !seenAbstract[key] {
			seenAbstract[key] = true
			r.abstract[obj.Name()] = append(r.abstract[obj.Name()], key)
		}
	}
	for key, sites := range r.byTarget {
		sort.Slice(sites, func(i, j int) bool {
			a, b := sites[i], sites[j]
			if a.file != b.file {
				return r.files[a.file] < r.files[b.file]
			}
			if a.line != b.line {
				return a.line < b.line
			}
			return a.col < b.col
		})
		r.byTarget[key] = sites
	}
	return r
}

// isAbstractMethod reports whether obj is a method of an interface type,
// whose calls reach an implementation chosen at run time.
func isAbstractMethod(obj types.Object) bool {
	f, ok := obj.(*types.Func)
	if !ok {
		return false
	}
	sig, ok := f.Type().(*types.Signature)
	if !ok || sig.Recv() == nil {
		return false
	}
	return types.IsInterface(sig.Recv().Type())
}

// calledIdents finds the identifiers in function position of a call:
// f(...), x.f(...), and (f)(...).
func calledIdents(files []*ast.File) map[*ast.Ident]bool {
	out := map[*ast.Ident]bool{}
	for _, f := range files {
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			if id := calleeIdent(call.Fun); id != nil {
				out[id] = true
			}
			return true
		})
	}
	return out
}

// calleeIdent returns the identifier a call expression's function
// position names, if it names one.
func calleeIdent(fun ast.Expr) *ast.Ident {
	switch e := ast.Unparen(fun).(type) {
	case *ast.Ident:
		return e
	case *ast.SelectorExpr:
		return e.Sel
	case *ast.IndexExpr: // a generic function instantiated explicitly
		return calleeIdent(e.X)
	case *ast.IndexListExpr:
		return calleeIdent(e.X)
	}
	return nil
}

// declSpanList maps positions in a package's files to the top-level
// declaration (or method) that contains them.
type declSpanList struct {
	byFile map[string][]declSpan
}

type declSpan struct {
	start, end token.Pos
	id         string
}

// declSpans records the extent of every declaration declTree finds,
// methods separately from their receiver types. A var or const spec with
// several names is attributed to its first name.
func declSpans(fset *token.FileSet, files []*ast.File, info *types.Info) *declSpanList {
	out := &declSpanList{byFile: map[string][]declSpan{}}
	seen := map[ast.Node]bool{}
	var walk func(n *declNode)
	walk = func(n *declNode) {
		switch n.node.(type) {
		case *ast.FuncDecl, *ast.TypeSpec, *ast.ValueSpec:
			if !seen[n.node] {
				seen[n.node] = true
				start, end := declExtent(n)
				out.byFile[n.path] = append(out.byFile[n.path], declSpan{start: start, end: end, id: n.id})
			}
		}
		for _, m := range n.members {
			walk(m)
		}
	}
	for _, n := range declTree(fset, files, info) {
		walk(n)
	}
	for path, spans := range out.byFile {
		sort.Slice(spans, func(i, j int) bool { return spans[i].start < spans[j].start })
		out.byFile[path] = spans
	}
	return out
}

// enclosing returns the id of the declaration containing pos in the
// file, or "" when none does.
func (l *declSpanList) enclosing(path string, pos token.Pos) string {
	spans := l.byFile[path]
	i := sort.Search(len(spans), func(i int) bool { return spans[i].start > pos })
	if i > 0 && pos < spans[i-1].end {
		return spans[i-1].id
	}
	return ""
}

// fieldOwners resolves a struct field object to its "Struct.Field"
// declaration, for uses without a selection, such as the keys of a
// composite literal. Owners are found by scanning the declaring package's
// named struct types, once per package.
type fieldOwners struct {
	owners map[*types.Var]*types.TypeName
	done   map[*types.Package]bool
}

func newFieldOwners() *fieldOwners {
	return &fieldOwners{owners: map[*types.Var]*types.TypeName{}, done: map[*types.Package]bool{}}
}

func (fo *fieldOwners) ref(v *types.Var) *pb.SymbolRef {
	pkg := v.Pkg()
	if pkg == nil {
		return nil
	}
	if !fo.done[pkg] {
		fo.done[pkg] = true
		scope := pkg.Scope()
		for _, name := range scope.Names() {
			tn, ok := scope.Lookup(name).(*types.TypeName)
			if !ok || tn.IsAlias() {
				continue
			}
			st, ok := tn.Type().Underlying().(*types.Struct)
			if !ok {
				continue
			}
			for i := range st.NumFields() {
				fo.owners[st.Field(i)] = tn
			}
		}
	}
	owner := fo.owners[v]
	if owner == nil {
		return nil
	}
	return &pb.SymbolRef{PackageId: pkg.Path(), DeclarationId: owner.Name() + "." + v.Name()}
}

// toProto serializes the references for the cache.
func (r *pkgRefs) toProto(id string) *pb.IndexedReferences {
	out := &pb.IndexedReferences{PackageId: id, Fingerprint: r.fingerprint, Files: r.files}
	pkgIndex := map[string]uint32{}
	enclIndex := map[string]uint32{}
	keys := make([]refKey, 0, len(r.byTarget))
	for k := range r.byTarget {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].pkg != keys[j].pkg {
			return keys[i].pkg < keys[j].pkg
		}
		return keys[i].decl < keys[j].decl
	})
	for _, k := range keys {
		pi, ok := pkgIndex[k.pkg]
		if !ok {
			pi = uint32(len(out.Packages))
			pkgIndex[k.pkg] = pi
			out.Packages = append(out.Packages, k.pkg)
		}
		for _, s := range r.byTarget[k] {
			var ei uint32
			if s.enclosing != "" {
				ei, ok = enclIndex[s.enclosing]
				if !ok {
					out.Enclosing = append(out.Enclosing, s.enclosing)
					ei = uint32(len(out.Enclosing))
					enclIndex[s.enclosing] = ei
				}
			}
			out.References = append(out.References, &pb.IndexedReference{
				Package: pi, DeclarationId: k.decl, File: s.file, Line: s.line, Column: s.col,
				Length: s.length, Call: s.call, InterfaceMethod: s.abstract, Enclosing: ei,
			})
		}
	}
	return out
}

// refsFromProto restores cached references.
func refsFromProto(d *pb.IndexedReferences) *pkgRefs {
	r := &pkgRefs{fingerprint: d.Fingerprint, files: d.Files, byTarget: map[refKey][]refSite{}, abstract: map[string][]refKey{}}
	seenAbstract := map[refKey]bool{}
	for _, ref := range d.References {
		if int(ref.Package) >= len(d.Packages) || int(ref.File) >= len(d.Files) || int(ref.Enclosing) > len(d.Enclosing) {
			continue
		}
		key := refKey{pkg: d.Packages[ref.Package], decl: ref.DeclarationId}
		site := refSite{
			file: ref.File, line: ref.Line, col: ref.Column, length: ref.Length,
			call: ref.Call, abstract: ref.InterfaceMethod,
		}
		if ref.Enclosing > 0 {
			site.enclosing = d.Enclosing[ref.Enclosing-1]
		}
		r.byTarget[key] = append(r.byTarget[key], site)
		if site.abstract && !seenAbstract[key] {
			seenAbstract[key] = true
			r.abstract[memberName(key.decl)] = append(r.abstract[memberName(key.decl)], key)
		}
	}
	return r
}

// memberName returns the last element of a declaration id.
func memberName(id string) string {
	for i := len(id) - 1; i >= 0; i-- {
		if id[i] == '.' {
			return id[i+1:]
		}
	}
	return id
}
