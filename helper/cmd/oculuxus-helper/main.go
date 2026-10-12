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
//
// DECL_ID is "Name" for a top-level declaration or "Type.Member" for a
// method or field.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"

	"google.golang.org/protobuf/encoding/protojson"

	"github.com/herbygillot/oculuxus/helper/internal/server"
	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

func main() {
	fs := flag.NewFlagSet("oculuxus-helper", flag.ExitOnError)
	debug := fs.Bool("debug-json", false, "log every protocol message to stderr as JSON")
	goBinary := fs.String("go", "", "Go binary to use instead of the one on PATH")
	tags := fs.String("tags", "", "comma-separated build tags")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: oculuxus-helper [flags] [serve | info | packages DIR | outline DIR PKG | source DIR PKG DECL | file DIR PKG FILE]")
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
		if err := s.Serve(ctx, os.Stdin, os.Stdout); err != nil {
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
		must(run(ctx, h, &pb.Request_OpenProject{OpenProject: &pb.OpenProjectRequest{RootDir: dir, GoBinary: *goBinary, BuildTags: buildTags}}, *debug))
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
		resp = run(ctx, h, &pb.Request_PackageOutline{PackageOutline: &pb.PackageOutlineRequest{PackageId: args[1]}}, *debug)
	case "source":
		need(3)
		open(args[0])
		resp = run(ctx, h, &pb.Request_DeclarationSource{DeclarationSource: &pb.DeclarationSourceRequest{PackageId: args[1], DeclarationId: args[2]}}, *debug)
	case "file":
		need(3)
		open(args[0])
		resp = run(ctx, h, &pb.Request_FileSource{FileSource: &pb.FileSourceRequest{PackageId: args[1], File: args[2]}}, *debug)
	default:
		fs.Usage()
		os.Exit(2)
	}
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
