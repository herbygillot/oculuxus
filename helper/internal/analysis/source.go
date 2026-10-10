package analysis

import (
	"fmt"
	"go/ast"
	"go/token"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// DeclarationSource returns one declaration's source with highlighting.
// For a member (field, interface method, or method) of a type it returns
// that member alone.
func (tp *typedPackage) DeclarationSource(id string) (*pb.DeclarationSourceResponse, error) {
	n, ok := tp.decls[id]
	if !ok {
		return nil, &Error{Code: pb.Error_NOT_FOUND, Err: fmt.Errorf("declaration %q not found in %s", id, tp.pkg.PkgPath)}
	}
	src := tp.sources[n.path]
	tf := tp.fset.File(n.file.Pos())
	startPos, endPos := declExtent(n)
	start, end := uint32(tf.Offset(startPos)), uint32(tf.Offset(endPos))
	if int(end) > len(src) {
		end = uint32(len(src))
	}
	return &pb.DeclarationSourceResponse{
		Source:   tp.highlightSource(n.file, src[start:end], start),
		Location: tp.location(startPos),
	}, nil
}

// declExtent returns the positions a declaration's source spans, from
// its doc comment to its end.
func declExtent(n *declNode) (token.Pos, token.Pos) {
	start, end := n.node.Pos(), n.node.End()
	if n.decl != nil && len(n.decl.Specs) == 1 {
		// A single-spec declaration shows the whole "type T ..." or
		// "var x ...", keywords included.
		start, end = n.decl.Pos(), n.decl.End()
	}
	if n.doc != nil && n.doc.Pos() < start {
		start = n.doc.Pos()
	}
	return start, end
}

// FileSource returns a whole file with highlighting and the ranges of the
// declarations in it.
func (tp *typedPackage) FileSource(path string) (*pb.FileSourceResponse, error) {
	var file *ast.File
	for _, f := range tp.pkg.Syntax {
		if tp.fset.File(f.Pos()).Name() == path {
			file = f
			break
		}
	}
	src, ok := tp.sources[path]
	if file == nil || !ok {
		return nil, &Error{Code: pb.Error_NOT_FOUND, Err: fmt.Errorf("file %q is not in %s", path, tp.pkg.PkgPath)}
	}
	resp := &pb.FileSourceResponse{Source: tp.highlightSource(file, src, 0)}
	tf := tp.fset.File(file.Pos())
	var walk func(n *declNode)
	walk = func(n *declNode) {
		if n.path == path {
			s, e := declExtent(n)
			resp.Declarations = append(resp.Declarations, &pb.DeclarationRange{
				DeclarationId: n.id,
				Range:         &pb.Range{Start: uint32(tf.Offset(s)), End: uint32(tf.Offset(e))},
			})
		}
		for _, m := range n.members {
			walk(m)
		}
	}
	for _, n := range tp.roots {
		walk(n)
	}
	return resp, nil
}
