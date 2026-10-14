// Command oculuxus-helper analyzes Go projects for the Oculuxus app.
//
// With no arguments it serves the protobuf protocol on stdin and stdout.
// The other subcommands run single requests and print the response as
// JSON, for trying the helper on a project without the app:
//
//	oculuxus-helper info
//	oculuxus-helper packages DIR
//	oculuxus-helper outline DIR IMPORT_PATH
//	oculuxus-helper source DIR IMPORT_PATH DECL_ID
//	oculuxus-helper file DIR IMPORT_PATH FILE
//	oculuxus-helper search DIR QUERY
//	oculuxus-helper refs DIR IMPORT_PATH DECL_ID
//	oculuxus-helper callers DIR IMPORT_PATH DECL_ID
//	oculuxus-helper callees DIR IMPORT_PATH DECL_ID
//	oculuxus-helper hover DIR IMPORT_PATH FILE OFFSET
//
// DECL_ID is "Name" for a top-level declaration or "Type.Member" for a
// method or field. -tests includes _test.go files in outlines and source;
// search, refs and callers wait for the index and, with -deps, cover
// dependencies and the standard library too. hover takes a byte offset
// into FILE.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/encoding/protojson"

	"github.com/herbygillot/oculuxus/helper/internal/server"
	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

func main() {
	fs := flag.NewFlagSet("oculuxus-helper", flag.ExitOnError)
	debug := fs.Bool("debug-json", false, "log every protocol message to stderr as JSON")
	goBinary := fs.String("go", "", "Go binary to use instead of the one on PATH")
	tags := fs.String("tags", "", "comma-separated build tags")
	goos := fs.String("goos", "", "target GOOS instead of the host's")
	goarch := fs.String("goarch", "", "target GOARCH instead of the host's")
	tests := fs.Bool("tests", false, "include _test.go files in outline, source and file")
	deps := fs.Bool("deps", false, "search dependencies and the standard library too")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: oculuxus-helper [flags] [serve | info | packages DIR | outline DIR PKG | source DIR PKG DECL | file DIR PKG FILE | search DIR QUERY | refs DIR PKG DECL | callers DIR PKG DECL | callees DIR PKG DECL | hover DIR PKG FILE OFFSET]")
		fs.PrintDefaults()
	}
	fs.Parse(os.Args[1:])
	args := fs.Args()
	cmd := "serve"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	h := &server.Handler{}

	if cmd == "serve" {
		s := server.NewServer(h)
		if *debug {
			s.DebugLog = log.New(os.Stderr, "", log.Lmicroseconds)
		}
		err := s.Serve(ctx, os.Stdin, os.Stdout)
		h.Close()
		if err != nil {
			fmt.Fprintln(os.Stderr, "oculuxus-helper:", err)
			os.Exit(1)
		}
		return
	}

	var buildTags []string
	if *tags != "" {
		buildTags = strings.Split(*tags, ",")
	}
	open := func(dir string) {
		must(run(ctx, h, &pb.Request_OpenProject{OpenProject: &pb.OpenProjectRequest{RootDir: dir, GoBinary: *goBinary, BuildTags: buildTags, Goos: *goos, Goarch: *goarch}}, *debug))
	}
	need := func(n int) {
		if len(args) < n {
			fs.Usage()
			os.Exit(2)
		}
	}
	var resp *pb.Response
	switch cmd {
	case "info":
		resp = run(ctx, h, &pb.Request_Info{Info: &pb.InfoRequest{}}, *debug)
	case "packages":
		need(1)
		open(args[0])
		resp = run(ctx, h, &pb.Request_ListPackages{ListPackages: &pb.ListPackagesRequest{}}, *debug)
	case "outline":
		need(2)
		open(args[0])
		resp = run(ctx, h, &pb.Request_PackageOutline{PackageOutline: &pb.PackageOutlineRequest{PackageId: args[1], IncludeTests: *tests}}, *debug)
	case "source":
		need(3)
		open(args[0])
		resp = run(ctx, h, &pb.Request_DeclarationSource{DeclarationSource: &pb.DeclarationSourceRequest{PackageId: args[1], DeclarationId: args[2], IncludeTests: *tests}}, *debug)
	case "file":
		need(3)
		open(args[0])
		resp = run(ctx, h, &pb.Request_FileSource{FileSource: &pb.FileSourceRequest{PackageId: args[1], File: args[2], IncludeTests: *tests}}, *debug)
	case "search":
		need(2)
		open(args[0])
		start := time.Now()
		resp = run(ctx, h, &pb.Request_Search{Search: &pb.SearchRequest{Query: args[1], IncludeDependencies: *deps, Wait: true}}, *debug)
		if *debug {
			fmt.Fprintf(os.Stderr, "… search took %v (including indexing)\n", time.Since(start))
			start = time.Now()
			run(ctx, h, &pb.Request_Search{Search: &pb.SearchRequest{Query: args[1], IncludeDependencies: *deps}}, false)
			fmt.Fprintf(os.Stderr, "… search again took %v\n", time.Since(start))
		}
	case "refs":
		need(3)
		open(args[0])
		start := time.Now()
		resp = run(ctx, h, &pb.Request_References{References: &pb.ReferencesRequest{
			At:                  &pb.ReferencesRequest_Symbol{Symbol: &pb.SymbolRef{PackageId: args[1], DeclarationId: args[2]}},
			IncludeDependencies: *deps, Wait: true,
		}}, *debug)
		if *debug {
			fmt.Fprintf(os.Stderr, "… refs took %v (including indexing)\n", time.Since(start))
		}
	case "callers", "callees":
		need(3)
		open(args[0])
		dir := pb.CallHierarchyRequest_CALLERS
		if cmd == "callees" {
			dir = pb.CallHierarchyRequest_CALLEES
		}
		resp = run(ctx, h, &pb.Request_CallHierarchy{CallHierarchy: &pb.CallHierarchyRequest{
			Symbol: &pb.SymbolRef{PackageId: args[1], DeclarationId: args[2]}, Direction: dir,
			IncludeDependencies: *deps, Wait: true,
		}}, *debug)
	case "hover":
		need(4)
		open(args[0])
		offset, err := strconv.ParseUint(args[3], 10, 32)
		if err != nil {
			fmt.Fprintln(os.Stderr, "oculuxus-helper: OFFSET must be a number")
			os.Exit(2)
		}
		resp = run(ctx, h, &pb.Request_Hover{Hover: &pb.HoverRequest{
			PackageId: args[1], IncludeTests: *tests,
			At: &pb.HoverRequest_Position{Position: &pb.Position{File: args[2], Offset: uint32(offset)}},
		}}, *debug)
	default:
		fs.Usage()
		os.Exit(2)
	}
	h.Close()
	must(resp)
	fmt.Println(protojson.MarshalOptions{Multiline: true, Indent: "  "}.Format(resp))
}

func run(ctx context.Context, h *server.Handler, body any, debug bool) *pb.Response {
	req := &pb.Request{Id: 1}
	switch b := body.(type) {
	case *pb.Request_Info:
		req.Body = b
	case *pb.Request_OpenProject:
		req.Body = b
	case *pb.Request_ListPackages:
		req.Body = b
	case *pb.Request_PackageOutline:
		req.Body = b
	case *pb.Request_DeclarationSource:
		req.Body = b
	case *pb.Request_FileSource:
		req.Body = b
	case *pb.Request_Search:
		req.Body = b
	case *pb.Request_References:
		req.Body = b
	case *pb.Request_CallHierarchy:
		req.Body = b
	case *pb.Request_Hover:
		req.Body = b
	}
	progress := func(msg string) {
		if debug {
			fmt.Fprintln(os.Stderr, "…", msg)
		}
	}
	return h.Handle(ctx, req, progress)
}

func must(resp *pb.Response) {
	if e, ok := resp.Body.(*pb.Response_Error); ok {
		fmt.Fprintf(os.Stderr, "oculuxus-helper: %s: %s\n", e.Error.Code, e.Error.Message)
		os.Exit(1)
	}
}
