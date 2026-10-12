package server

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/encoding/protodelim"

	"github.com/herbygillot/oculuxus/helper/internal/analysis"
	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// client talks to a Server over in-process pipes.
type client struct {
	t    *testing.T
	w    io.WriteCloser
	r    *bufio.Reader
	done chan error
}

func startServer(t *testing.T) *client {
	t.Helper()
	reqR, reqW := io.Pipe()
	respR, respW := io.Pipe()
	s := NewServer(&Handler{})
	done := make(chan error, 1)
	go func() {
		done <- s.Serve(context.Background(), reqR, respW)
		respW.Close()
	}()
	return &client{t: t, w: reqW, r: bufio.NewReader(respR), done: done}
}

func (c *client) send(req *pb.Request) {
	c.t.Helper()
	if _, err := protodelim.MarshalTo(c.w, req); err != nil {
		c.t.Fatal(err)
	}
}

func (c *client) recv() *pb.Response {
	c.t.Helper()
	resp := &pb.Response{}
	if err := protodelim.UnmarshalFrom(c.r, resp); err != nil {
		c.t.Fatal(err)
	}
	return resp
}

// final reads responses until the final one for id, skipping progress.
func (c *client) final(id uint64) *pb.Response {
	c.t.Helper()
	for {
		resp := c.recv()
		if resp.Id != id {
			c.t.Fatalf("got response for %d while waiting for %d", resp.Id, id)
		}
		if _, ok := resp.Body.(*pb.Response_Progress); ok {
			continue
		}
		return resp
	}
}

func TestProtocol(t *testing.T) {
	c := startServer(t)

	c.send(&pb.Request{Id: 1, Body: &pb.Request_Info{Info: &pb.InfoRequest{}}})
	info := c.final(1).GetInfo()
	if info == nil || info.ProtocolVersion != ProtocolVersion {
		t.Fatalf("info = %+v", info)
	}

	// Zero ids are rejected.
	c.send(&pb.Request{Id: 0, Body: &pb.Request_Info{Info: &pb.InfoRequest{}}})
	if e := c.recv().GetError(); e == nil || e.Code != pb.Error_INVALID_REQUEST {
		t.Fatalf("expected INVALID_REQUEST for id 0, got %+v", e)
	}

	// Requests need an open project.
	c.send(&pb.Request{Id: 2, Body: &pb.Request_ListPackages{ListPackages: &pb.ListPackagesRequest{}}})
	if e := c.final(2).GetError(); e == nil || e.Code != pb.Error_NO_PROJECT {
		t.Fatalf("expected NO_PROJECT, got %+v", e)
	}

	root, _ := filepath.Abs(filepath.Join("..", "analysis", "testdata", "simple"))
	c.send(&pb.Request{Id: 3, Body: &pb.Request_OpenProject{OpenProject: &pb.OpenProjectRequest{RootDir: root}}})
	open := c.final(3)
	if e := open.GetError(); e != nil {
		if e.Code == pb.Error_GO_TOOLCHAIN {
			t.Skip(e.Message)
		}
		t.Fatalf("open: %+v", e)
	}
	if open.GetOpenProject().Project.RootDir != root {
		t.Errorf("project = %+v", open.GetOpenProject().Project)
	}

	c.send(&pb.Request{Id: 4, Body: &pb.Request_PackageOutline{PackageOutline: &pb.PackageOutlineRequest{PackageId: "example.com/simple/shapes"}}})
	outline := c.final(4).GetPackageOutline()
	if outline == nil || outline.Outline.Name != "shapes" {
		t.Fatalf("outline = %+v", outline)
	}

	c.send(&pb.Request{Id: 5, Body: &pb.Request_DeclarationSource{DeclarationSource: &pb.DeclarationSourceRequest{PackageId: "example.com/simple/shapes", DeclarationId: "Circle.Area"}}})
	src := c.final(5).GetDeclarationSource()
	if src == nil || src.Source.Text == "" {
		t.Fatalf("source = %+v", src)
	}

	// Cancelling an unknown request is harmless.
	c.send(&pb.Request{Id: 6, Body: &pb.Request_Cancel{Cancel: &pb.Cancel{RequestId: 999}}})
	if c.final(6).GetEmpty() == nil {
		t.Error("cancel should answer Empty")
	}

	c.send(&pb.Request{Id: 7, Body: &pb.Request_Shutdown{Shutdown: &pb.Shutdown{}}})
	if c.final(7).GetEmpty() == nil {
		t.Error("shutdown should answer Empty")
	}
	if err := <-c.done; err != nil {
		t.Errorf("Serve: %v", err)
	}
}

func TestCancelInFlight(t *testing.T) {
	// A request that blocks until cancelled: open a project whose go
	// command never returns is hard to arrange, so exercise the Handler
	// directly with a pre-cancelled context.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	h := &Handler{}
	resp := h.Handle(ctx, &pb.Request{Id: 1, Body: &pb.Request_Info{Info: &pb.InfoRequest{}}}, func(string) {})
	if e := resp.GetError(); e == nil || e.Code != pb.Error_CANCELLED {
		t.Fatalf("expected CANCELLED, got %+v", resp)
	}
}

func TestCancelledLoadIsCancelled(t *testing.T) {
	// go/packages reports a cancelled load as a load failure.
	err := &analysis.Error{Code: pb.Error_LOAD_FAILED, Err: fmt.Errorf("go list: %w", context.Canceled)}
	if got := analysis.ErrorProto(err).Code; got != pb.Error_CANCELLED {
		t.Fatalf("expected CANCELLED, got %v", got)
	}
}
