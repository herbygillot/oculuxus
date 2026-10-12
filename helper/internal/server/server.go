// Package server runs the helper protocol over a pair of streams.
package server

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"sync"

	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"github.com/herbygillot/oculuxus/helper/internal/analysis"
	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// ProtocolVersion is bumped on incompatible changes to the .proto schema.
const ProtocolVersion = 1

// Version is the helper's version, set by the build.
var Version = "dev"

// Handler executes requests against the open project. It is shared by the
// stdio server and the command-line subcommands.
type Handler struct {
	mu      sync.Mutex
	project *analysis.Project
}

// Server reads requests from r and writes responses to w.
type Server struct {
	Handler *Handler
	// DebugLog receives every message in protobuf JSON, when set.
	DebugLog *log.Logger

	w       *bufio.Writer
	writeMu sync.Mutex

	mu       sync.Mutex
	inflight map[uint64]context.CancelFunc
	wg       sync.WaitGroup
}

// NewServer returns a server for the streams.
func NewServer(h *Handler) *Server {
	return &Server{Handler: h, inflight: map[uint64]context.CancelFunc{}}
}

// Serve handles requests until r reaches EOF or a Shutdown request
// arrives, then waits for in-flight requests to finish.
func (s *Server) Serve(ctx context.Context, r io.Reader, w io.Writer) error {
	ctx, cancelAll := context.WithCancel(ctx)
	defer cancelAll()
	s.w = bufio.NewWriter(w)
	br := bufio.NewReader(r)
	for {
		req := &pb.Request{}
		if err := protodelim.UnmarshalFrom(br, req); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			if errors.Is(err, io.ErrUnexpectedEOF) {
				break
			}
			s.wg.Wait()
			return fmt.Errorf("reading request: %w", err)
		}
		s.logMessage("<-", req)
		if _, ok := req.Body.(*pb.Request_Shutdown); ok {
			s.send(&pb.Response{Id: req.Id, Body: &pb.Response_Empty{Empty: &pb.Empty{}}})
			break
		}
		s.dispatch(ctx, req)
	}
	cancelAll()
	s.wg.Wait()
	return nil
}

func (s *Server) dispatch(ctx context.Context, req *pb.Request) {
	if req.Id == 0 {
		s.send(&pb.Response{Id: 0, Body: &pb.Response_Error{Error: &pb.Error{Code: pb.Error_INVALID_REQUEST, Message: "request id must be non-zero"}}})
		return
	}
	if c, ok := req.Body.(*pb.Request_Cancel); ok {
		s.mu.Lock()
		cancel := s.inflight[c.Cancel.RequestId]
		s.mu.Unlock()
		if cancel != nil {
			cancel()
		}
		s.send(&pb.Response{Id: req.Id, Body: &pb.Response_Empty{Empty: &pb.Empty{}}})
		return
	}
	ctx, cancel := context.WithCancel(ctx)
	s.mu.Lock()
	s.inflight[req.Id] = cancel
	s.mu.Unlock()
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer cancel()
		defer func() {
			s.mu.Lock()
			delete(s.inflight, req.Id)
			s.mu.Unlock()
		}()
		progress := func(msg string) {
			s.send(&pb.Response{Id: req.Id, Body: &pb.Response_Progress{Progress: &pb.Progress{Message: msg}}})
		}
		resp := s.Handler.Handle(ctx, req, progress)
		resp.Id = req.Id
		s.send(resp)
	}()
}

func (s *Server) send(resp *pb.Response) {
	s.logMessage("->", resp)
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if _, err := protodelim.MarshalTo(s.w, resp); err != nil {
		fmt.Fprintln(os.Stderr, "oculuxus-helper: write:", err)
		return
	}
	if err := s.w.Flush(); err != nil {
		fmt.Fprintln(os.Stderr, "oculuxus-helper: flush:", err)
	}
}

func (s *Server) logMessage(dir string, m proto.Message) {
	if s.DebugLog == nil {
		return
	}
	s.DebugLog.Printf("%s %s", dir, protojson.Format(m))
}

// Handle executes one request and returns its final response. progress
// may be called any number of times before Handle returns.
func (h *Handler) Handle(ctx context.Context, req *pb.Request, progress func(string)) *pb.Response {
	resp, err := h.handle(ctx, req, progress)
	if err == nil && ctx.Err() != nil {
		err = ctx.Err()
	}
	if err != nil {
		return &pb.Response{Body: &pb.Response_Error{Error: analysis.ErrorProto(err)}}
	}
	return resp
}

func (h *Handler) current() (*analysis.Project, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.project == nil {
		return nil, &analysis.Error{Code: pb.Error_NO_PROJECT, Err: errors.New("no project is open")}
	}
	return h.project, nil
}

func (h *Handler) handle(ctx context.Context, req *pb.Request, progress func(string)) (*pb.Response, error) {
	switch r := req.Body.(type) {
	case *pb.Request_Info:
		tc, err := analysis.ResolveToolchain(ctx, "")
		resp := &pb.InfoResponse{ProtocolVersion: ProtocolVersion, HelperVersion: Version}
		if err == nil {
			resp.GoVersion = tc.GoVersion
			resp.Goroot = tc.GOROOT
		}
		return &pb.Response{Body: &pb.Response_Info{Info: resp}}, nil

	case *pb.Request_OpenProject:
		progress("Checking Go toolchain")
		tc, err := analysis.ResolveToolchain(ctx, r.OpenProject.GoBinary)
		if err != nil {
			return nil, err
		}
		progress("Reading modules")
		p, err := analysis.Open(ctx, tc, r.OpenProject.RootDir, r.OpenProject.BuildTags)
		if err != nil {
			return nil, err
		}
		h.mu.Lock()
		h.project = p
		h.mu.Unlock()
		return &pb.Response{Body: &pb.Response_OpenProject{OpenProject: &pb.OpenProjectResponse{Project: p.Proto()}}}, nil

	case *pb.Request_CloseProject:
		h.mu.Lock()
		h.project = nil
		h.mu.Unlock()
		return &pb.Response{Body: &pb.Response_Empty{Empty: &pb.Empty{}}}, nil

	case *pb.Request_ListPackages:
		p, err := h.current()
		if err != nil {
			return nil, err
		}
		progress("Listing packages")
		list, err := p.ListPackages(ctx)
		if err != nil {
			return nil, err
		}
		return &pb.Response{Body: &pb.Response_ListPackages{ListPackages: list}}, nil

	case *pb.Request_PackageOutline:
		p, err := h.current()
		if err != nil {
			return nil, err
		}
		progress("Type-checking " + r.PackageOutline.PackageId)
		tp, err := p.Typed(ctx, r.PackageOutline.PackageId)
		if err != nil {
			return nil, err
		}
		return &pb.Response{Body: &pb.Response_PackageOutline{PackageOutline: &pb.PackageOutlineResponse{Outline: tp.Outline()}}}, nil

	case *pb.Request_DeclarationSource:
		p, err := h.current()
		if err != nil {
			return nil, err
		}
		tp, err := p.Typed(ctx, r.DeclarationSource.PackageId)
		if err != nil {
			return nil, err
		}
		src, err := tp.DeclarationSource(r.DeclarationSource.DeclarationId)
		if err != nil {
			return nil, err
		}
		return &pb.Response{Body: &pb.Response_DeclarationSource{DeclarationSource: src}}, nil

	case *pb.Request_FileSource:
		p, err := h.current()
		if err != nil {
			return nil, err
		}
		tp, err := p.Typed(ctx, r.FileSource.PackageId)
		if err != nil {
			return nil, err
		}
		src, err := tp.FileSource(r.FileSource.File)
		if err != nil {
			return nil, err
		}
		return &pb.Response{Body: &pb.Response_FileSource{FileSource: src}}, nil

	case *pb.Request_Reload:
		p, err := h.current()
		if err != nil {
			return nil, err
		}
		return &pb.Response{Body: &pb.Response_Reload{Reload: p.Reload(r.Reload.ChangedFiles)}}, nil

	case *pb.Request_Shutdown, *pb.Request_Cancel:
		return &pb.Response{Body: &pb.Response_Empty{Empty: &pb.Empty{}}}, nil
	}
	return nil, &analysis.Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("unknown request type %T", req.Body)}
}
