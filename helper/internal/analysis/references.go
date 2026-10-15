package analysis

import (
	"bytes"
	"context"
	"fmt"
	"go/ast"
	"go/printer"
	"go/token"
	"go/types"
	"os"
	"sort"
	"strings"
	"time"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

const defaultReferenceLimit = 2000

// References finds every use of a declaration in the project, and in
// its dependencies when asked. It lists packages first if needed, which
// starts the index, then waits for the project's packages to be
// type-checked, reporting progress. Dependencies are searched as far as
// they are indexed unless req.Wait is set.
func (p *Project) References(ctx context.Context, req *pb.ReferencesRequest, progress func(string)) (*pb.ReferencesResponse, error) {
	if _, err := p.ListPackages(ctx); err != nil {
		return nil, err
	}
	target, local, err := p.resolveTarget(ctx, req)
	if err != nil {
		return nil, err
	}
	if local != nil {
		return local, nil
	}
	hits, st, err := p.collectReferences(ctx, target, req.IncludeDependencies, req.Wait, progress)
	if err != nil {
		return nil, err
	}
	limit := int(req.Limit)
	if limit <= 0 {
		limit = defaultReferenceLimit
	}
	resp := &pb.ReferencesResponse{
		Symbol:          target,
		Total:           uint32(len(hits)),
		Complete:        st.complete(),
		IndexedPackages: uint32(st.indexed),
		TotalPackages:   uint32(st.total),
	}
	if len(hits) > limit {
		hits = hits[:limit]
	}
	resp.References = hits
	return resp, nil
}

// resolveTarget turns the request into a declaration. A position on a
// local variable or parameter has no declaration; its uses are found in
// the type-checked package and returned as a complete response.
func (p *Project) resolveTarget(ctx context.Context, req *pb.ReferencesRequest) (*pb.SymbolRef, *pb.ReferencesResponse, error) {
	switch at := req.At.(type) {
	case *pb.ReferencesRequest_Symbol:
		if at.Symbol == nil || at.Symbol.PackageId == "" || at.Symbol.DeclarationId == "" {
			return nil, nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("references: symbol needs a package and declaration id")}
		}
		return at.Symbol, nil, nil
	case *pb.ReferencesRequest_Position:
		if at.Position == nil || req.PackageId == "" {
			return nil, nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("references: position needs a package id and file")}
		}
		tp, err := p.Typed(ctx, req.PackageId, req.IncludeTests)
		if err != nil {
			return nil, nil, err
		}
		id := tp.identAt(at.Position.File, at.Position.Offset)
		if id == nil {
			return nil, nil, &Error{Code: pb.Error_NOT_FOUND, Err: fmt.Errorf("no identifier at %s:%d", at.Position.File, at.Position.Offset)}
		}
		obj := tp.objectOf(id)
		if obj == nil {
			return nil, nil, &Error{Code: pb.Error_NOT_FOUND, Err: fmt.Errorf("%s has no declaration", id.Name)}
		}
		if ref := tp.refFor(id, obj); ref != nil && ref.DeclarationId != "" {
			return ref, nil, nil
		}
		return nil, tp.localReferences(obj), nil
	}
	return nil, nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("references: nothing to look up")}
}

// localReferences lists the uses of an object with no navigable
// declaration (a local variable, parameter, or label) in its package.
func (tp *typedPackage) localReferences(obj types.Object) *pb.ReferencesResponse {
	resp := &pb.ReferencesResponse{Complete: true}
	lines := lineCache{}
	spans := declSpans(tp.fset, tp.pkg.Syntax, tp.pkg.TypesInfo)
	called := calledIdents(tp.pkg.Syntax)
	var ids []*ast.Ident
	for id, o := range tp.pkg.TypesInfo.Uses {
		if o == obj {
			ids = append(ids, id)
		}
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i].Pos() < ids[j].Pos() })
	for _, id := range ids {
		pos := tp.fset.Position(id.Pos())
		resp.References = append(resp.References, tp.reference(lines, pos, uint32(len(id.Name)), called[id], spans.enclosing(pos.Filename, id.Pos()), ""))
	}
	resp.Total = uint32(len(resp.References))
	resp.IndexedPackages, resp.TotalPackages = 1, 1
	return resp
}

// identAt finds the identifier at a byte offset in a file of the package.
func (tp *typedPackage) identAt(path string, offset uint32) *ast.Ident {
	for _, f := range tp.pkg.Syntax {
		tf := tp.fset.File(f.Pos())
		if tf.Name() != path {
			continue
		}
		if int(offset) >= tf.Size() {
			return nil
		}
		pos := tf.Pos(int(offset))
		var found *ast.Ident
		ast.Inspect(f, func(n ast.Node) bool {
			if n == nil || found != nil || pos < n.Pos() || pos >= n.End() {
				return false
			}
			if id, ok := n.(*ast.Ident); ok {
				found = id
				return false
			}
			return true
		})
		return found
	}
	return nil
}

// objectOf returns the object an identifier uses or defines.
func (tp *typedPackage) objectOf(id *ast.Ident) types.Object {
	if obj := tp.pkg.TypesInfo.Uses[id]; obj != nil {
		return obj
	}
	return tp.pkg.TypesInfo.Defs[id]
}

// refFor resolves an identifier's object to a navigable declaration.
func (tp *typedPackage) refFor(id *ast.Ident, obj types.Object) *pb.SymbolRef {
	if v, ok := obj.(*types.Var); ok && v.IsField() {
		return tp.fieldRefFor(id, v)
	}
	if declID, ok := tp.byObj[obj]; ok {
		return &pb.SymbolRef{PackageId: tp.pkg.PkgPath, DeclarationId: declID}
	}
	return objectRef(obj)
}

// collectReferences gathers the indexed uses of a declaration in scope,
// waiting for the index as the request allows. For a concrete method it
// adds the uses of every interface method it implements, marked as going
// through that interface.
func (p *Project) collectReferences(ctx context.Context, target *pb.SymbolRef, deps, wait bool, progress func(string)) ([]*pb.Reference, indexStatus, error) {
	if deps {
		p.index.requestDeps()
	}
	var entries []refsEntry
	var st indexStatus
	lastReport := time.Time{}
	for {
		var changed <-chan struct{}
		entries, st, changed = p.index.snapshotRefs(deps)
		_, project, _ := p.index.snapshotRefs(false)
		if st.complete() || (!wait && project.complete()) {
			break
		}
		if time.Since(lastReport) > 100*time.Millisecond {
			progress(fmt.Sprintf("Type-checking %d of %d packages", st.indexed, st.total))
			lastReport = time.Now()
		}
		select {
		case <-changed:
		case <-ctx.Done():
			return nil, st, ctx.Err()
		}
	}

	direct := refKey{pkg: target.PackageId, decl: target.DeclarationId}
	via, err := p.interfacesFor(ctx, target, entries)
	if err != nil {
		return nil, st, err
	}
	lines := lineCache{}
	var hits []*pb.Reference
	for _, e := range entries {
		add := func(key refKey, viaName string) {
			for _, s := range e.refs.byTarget[key] {
				if int(s.file) >= len(e.refs.files) {
					continue
				}
				pos := token.Position{Filename: e.refs.files[s.file], Line: int(s.line), Column: int(s.col)}
				r := lines.reference(pos, s.length, s.call, s.enclosing, viaName)
				r.PackageId, r.PackageName, r.Origin = e.target.id, e.target.name, e.target.origin
				hits = append(hits, r)
			}
		}
		add(direct, "")
		for key, name := range via {
			add(key, name)
		}
	}
	sort.SliceStable(hits, func(i, j int) bool {
		a, b := hits[i], hits[j]
		if ra, rb := originRank(a.Origin), originRank(b.Origin); ra != rb {
			return ra < rb
		}
		if a.PackageId != b.PackageId {
			return a.PackageId < b.PackageId
		}
		if a.Location.File != b.Location.File {
			return a.Location.File < b.Location.File
		}
		if a.Location.Line != b.Location.Line {
			return a.Location.Line < b.Location.Line
		}
		return a.Location.Column < b.Location.Column
	})
	return hits, st, nil
}

// interfacesFor finds the interface methods a concrete method
// implements, among those the indexed packages reference: the keys of
// the uses that reach the method through an interface, each with the
// interface's display name such as "io.Reader".
func (p *Project) interfacesFor(ctx context.Context, target *pb.SymbolRef, entries []refsEntry) (map[refKey]string, error) {
	typeName, method, ok := strings.Cut(target.DeclarationId, ".")
	if !ok {
		return nil, nil
	}
	tp, err := p.Typed(ctx, target.PackageId, false)
	if err != nil {
		return nil, err
	}
	n := tp.decls[target.DeclarationId]
	if n == nil || n.kind != pb.SymbolKind_METHOD {
		return nil, nil
	}
	if _, isFunc := n.node.(*ast.FuncDecl); !isFunc {
		return nil, nil // an interface method itself
	}
	tn, ok := tp.pkg.Types.Scope().Lookup(typeName).(*types.TypeName)
	if !ok {
		return nil, nil
	}
	methods := methodSignatures(tn.Type())
	candidates := map[refKey]bool{}
	for _, e := range entries {
		for _, key := range e.refs.abstract[method] {
			candidates[key] = true
		}
	}
	out := map[refKey]string{}
	for key := range candidates {
		if key.pkg == target.PackageId && key.decl == target.DeclarationId {
			continue
		}
		ifaceName, _, _ := strings.Cut(key.decl, ".")
		itp, err := p.Typed(ctx, key.pkg, false)
		if err != nil {
			if ctx.Err() != nil {
				return nil, err
			}
			continue
		}
		itn, ok := itp.pkg.Types.Scope().Lookup(ifaceName).(*types.TypeName)
		if !ok {
			continue
		}
		iface, ok := itn.Type().Underlying().(*types.Interface)
		if !ok || !implementsBySignature(methods, iface) {
			continue
		}
		out[key] = itp.pkg.Name + "." + ifaceName
	}
	return out, nil
}

// nameQualifier prints other packages by name and the local one not at
// all, as source in the package would.
func nameQualifier(local *types.Package) types.Qualifier {
	return func(pkg *types.Package) string {
		if pkg == local {
			return ""
		}
		return pkg.Name()
	}
}

// pathQualifier prints package paths in type strings, so that types from
// separately loaded packages compare by name.
func pathQualifier(pkg *types.Package) string { return pkg.Path() }

// methodSignatures maps a type's method names (pointer receiver
// included) to their signatures, printed with full package paths.
func methodSignatures(t types.Type) map[string]string {
	out := map[string]string{}
	for _, mt := range []types.Type{t, types.NewPointer(t)} {
		ms := types.NewMethodSet(mt)
		for i := range ms.Len() {
			m := ms.At(i)
			if _, ok := out[m.Obj().Name()]; ok {
				continue
			}
			out[m.Obj().Name()] = types.TypeString(m.Type(), pathQualifier)
		}
	}
	return out
}

// implementsBySignature reports whether a type with the given methods
// has every method of the interface, comparing signatures as text.
// Types from separate loads are distinct objects, so the type checker's
// Implements cannot be used across packages.
func implementsBySignature(methods map[string]string, iface *types.Interface) bool {
	if iface.NumMethods() == 0 {
		return false
	}
	for i := range iface.NumMethods() {
		m := iface.Method(i)
		if methods[m.Name()] != types.TypeString(m.Type(), pathQualifier) {
			return false
		}
	}
	return true
}

// lineCache reads source lines for references, each file once.
type lineCache map[string][][]byte

func (c lineCache) line(path string, n int) ([]byte, bool) {
	lines, ok := c[path]
	if !ok {
		data, err := os.ReadFile(path)
		if err == nil {
			lines = bytes.Split(data, []byte("\n"))
		}
		c[path] = lines
	}
	if n < 1 || n > len(lines) {
		return nil, false
	}
	return bytes.TrimRight(lines[n-1], "\r"), true
}

// reference builds the message for one use: the source line without its
// leading whitespace, and the identifier's range in it.
func (c lineCache) reference(pos token.Position, length uint32, call bool, enclosing, via string) *pb.Reference {
	r := &pb.Reference{
		Location:     &pb.Location{File: pos.Filename, Line: uint32(pos.Line), Column: uint32(pos.Column)},
		Call:         call,
		ViaInterface: via != "",
		Via:          via,
		EnclosingId:  enclosing,
	}
	line, ok := c.line(pos.Filename, pos.Line)
	if !ok {
		return r
	}
	trimmed := bytes.TrimLeft(line, " \t")
	indent := len(line) - len(trimmed)
	start := pos.Column - 1 - indent
	if start < 0 || start > len(trimmed) {
		start = 0
		length = 0
	}
	end := min(start+int(length), len(trimmed))
	r.LineText = string(trimmed)
	r.Range = &pb.Range{Start: uint32(start), End: uint32(end)}
	return r
}

func (tp *typedPackage) reference(lines lineCache, pos token.Position, length uint32, call bool, enclosing, via string) *pb.Reference {
	r := lines.reference(pos, length, call, enclosing, via)
	r.PackageId, r.PackageName = tp.pkg.PkgPath, tp.pkg.Name
	return r
}

// CallHierarchy lists one level of callers or callees of a function.
func (p *Project) CallHierarchy(ctx context.Context, req *pb.CallHierarchyRequest, progress func(string)) (*pb.CallHierarchyResponse, error) {
	if req.Symbol == nil || req.Symbol.PackageId == "" || req.Symbol.DeclarationId == "" {
		return nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("call hierarchy: symbol needs a package and declaration id")}
	}
	if _, err := p.ListPackages(ctx); err != nil {
		return nil, err
	}
	switch req.Direction {
	case pb.CallHierarchyRequest_CALLERS:
		return p.callers(ctx, req, progress)
	case pb.CallHierarchyRequest_CALLEES:
		return p.callees(ctx, req.Symbol)
	}
	return nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("call hierarchy: direction must be CALLERS or CALLEES")}
}

// callers groups the indexed calls of the function by the declaration
// that makes them.
func (p *Project) callers(ctx context.Context, req *pb.CallHierarchyRequest, progress func(string)) (*pb.CallHierarchyResponse, error) {
	hits, st, err := p.collectReferences(ctx, req.Symbol, req.IncludeDependencies, req.Wait, progress)
	if err != nil {
		return nil, err
	}
	resp := &pb.CallHierarchyResponse{
		Complete:        st.complete(),
		IndexedPackages: uint32(st.indexed),
		TotalPackages:   uint32(st.total),
	}
	items := map[string]*pb.CallHierarchyItem{}
	for _, h := range hits {
		if !h.Call {
			continue
		}
		key := h.PackageId + "#" + h.EnclosingId
		item, ok := items[key]
		if !ok {
			item = &pb.CallHierarchyItem{
				Symbol:      &pb.SymbolRef{PackageId: h.PackageId, DeclarationId: h.EnclosingId},
				PackageName: h.PackageName,
				Origin:      h.Origin,
				CallKind:    pb.CallHierarchyItem_VIA_INTERFACE,
			}
			if sym, files, ok := p.index.symbolFor(h.PackageId, h.EnclosingId); ok {
				item.Kind, item.Signature = sym.kind, sym.signature
				if int(sym.file) < len(files) {
					item.Location = &pb.Location{File: files[sym.file], Line: sym.line, Column: sym.column}
				}
			} else if h.EnclosingId == "" {
				item.Signature = "package " + h.PackageName
			} else {
				item.Signature = h.EnclosingId
			}
			items[key] = item
			resp.Items = append(resp.Items, item)
		}
		if !h.ViaInterface {
			item.CallKind, item.Via = pb.CallHierarchyItem_DIRECT, ""
		} else if item.CallKind == pb.CallHierarchyItem_VIA_INTERFACE && item.Via == "" {
			item.Via = h.Via
		}
		item.Sites = append(item.Sites, h)
	}
	return resp, nil
}

// callees lists the calls made in the function's body, grouped by what
// they call. Calls through interfaces and function values are labelled,
// since their target is not known statically.
func (p *Project) callees(ctx context.Context, sym *pb.SymbolRef) (*pb.CallHierarchyResponse, error) {
	tp, err := p.Typed(ctx, sym.PackageId, false)
	if err != nil {
		return nil, err
	}
	n, ok := tp.decls[sym.DeclarationId]
	if !ok {
		return nil, &Error{Code: pb.Error_NOT_FOUND, Err: fmt.Errorf("declaration %q not found in %s", sym.DeclarationId, sym.PackageId)}
	}
	resp := &pb.CallHierarchyResponse{Complete: true, IndexedPackages: 1, TotalPackages: 1}
	info := tp.pkg.TypesInfo
	lines := lineCache{}
	items := map[string]*pb.CallHierarchyItem{}
	qual := nameQualifier(tp.pkg.Types)
	ast.Inspect(n.node, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return true
		}
		fun := ast.Unparen(call.Fun)
		item := &pb.CallHierarchyItem{CallKind: pb.CallHierarchyItem_FUNCTION_VALUE}
		var key string
		at := fun.Pos()
		length := uint32(0)
		if id := calleeIdent(fun); id != nil {
			obj := info.Uses[id]
			switch o := obj.(type) {
			case nil, *types.Builtin, *types.TypeName, *types.Nil:
				return true // a builtin or a conversion
			case *types.Func:
				item.CallKind = pb.CallHierarchyItem_DIRECT
				item.Kind = pb.SymbolKind_FUNC
				if sig, ok := o.Type().(*types.Signature); ok && sig.Recv() != nil {
					item.Kind = pb.SymbolKind_METHOD
					if types.IsInterface(sig.Recv().Type()) {
						item.CallKind = pb.CallHierarchyItem_VIA_INTERFACE
						item.Via = "interface"
						if named := namedOf(sig.Recv().Type()); named != nil {
							item.Via = types.TypeString(named, qual)
						}
					}
				}
				item.Symbol = tp.refFor(id, o)
				item.Signature = types.ObjectString(o, qual)
			case *types.Var:
				item.Kind = pb.SymbolKind_VAR
				if o.IsField() {
					item.Kind = pb.SymbolKind_FIELD
				}
				item.Symbol = tp.refFor(id, o)
				item.Signature = types.ObjectString(o, qual)
			default:
				return true
			}
			at = id.Pos()
			length = uint32(len(id.Name))
			if obj.Pos().IsValid() {
				item.Location = tp.location(obj.Pos())
			}
			if item.Symbol != nil && item.Symbol.DeclarationId != "" {
				key = item.Symbol.PackageId + "#" + item.Symbol.DeclarationId
			} else {
				key = fmt.Sprintf("obj:%p", obj)
			}
			if pkg := obj.Pkg(); pkg != nil {
				item.PackageName = pkg.Name()
				if item.Symbol == nil {
					item.Symbol = &pb.SymbolRef{PackageId: pkg.Path()}
				}
			}
		} else {
			item.Signature = exprText(tp.fset, fun)
			key = "expr:" + item.Signature
		}
		if item.Symbol != nil {
			item.Origin = p.originOf(item.Symbol.PackageId)
			// The declaration as the outline shows it, once indexed.
			if item.Symbol.DeclarationId != "" {
				if sym, _, ok := p.index.symbolFor(item.Symbol.PackageId, item.Symbol.DeclarationId); ok {
					item.Signature = sym.signature
				}
			}
		}
		existing, ok := items[key]
		if !ok {
			items[key] = item
			resp.Items = append(resp.Items, item)
			existing = item
		}
		pos := tp.fset.Position(at)
		existing.Sites = append(existing.Sites, tp.reference(lines, pos, length, true, sym.DeclarationId, ""))
		return true
	})
	return resp, nil
}

// originOf reports where a listed package comes from.
func (p *Project) originOf(pkgID string) pb.PackageOrigin {
	p.mu.Lock()
	defer p.mu.Unlock()
	if pkg, ok := p.meta[pkgID]; ok {
		return p.origin(pkg)
	}
	return pb.PackageOrigin_PACKAGE_ORIGIN_UNSPECIFIED
}

// exprText prints an expression on one line, shortened when long.
func exprText(fset *token.FileSet, e ast.Expr) string {
	var buf bytes.Buffer
	cfg := printer.Config{Mode: printer.UseSpaces, Tabwidth: 4}
	if err := cfg.Fprint(&buf, fset, e); err != nil {
		return "function value"
	}
	text := collapse(buf.String())
	if len(text) > 60 {
		text = text[:57] + "..."
	}
	return text
}
