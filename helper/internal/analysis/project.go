// Package analysis loads Go projects with go/packages and turns them into
// protocol messages: package lists, outlines, and highlighted source.
package analysis

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"golang.org/x/tools/go/packages"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// Project is an open Go project: a folder with a go.work or go.mod file.
// It caches the package list and the type-checked packages requested so
// far. Methods are safe for concurrent use.
type Project struct {
	root       string
	configFile string
	workspace  bool
	modules    []*pb.Module
	env        []string // environment for the go command
	buildFlags []string
	goVersion  string

	mu       sync.Mutex
	list     *pb.ListPackagesResponse
	meta     map[string]*packages.Package // metadata-only packages by import path
	typed    map[string]*typedPackage     // type-checked packages by import path
	inflight map[string]*sync.WaitGroup
}

// Toolchain describes the Go binary the helper uses.
type Toolchain struct {
	Binary    string // the `go` binary to run
	GOROOT    string
	GoVersion string // output of `go version`
	Env       []string
}

// ResolveToolchain finds the Go binary to use. With an empty path it uses
// the `go` on PATH. A user-picked binary may be a plain download named
// go1.27.0 or similar; its GOROOT/bin/go is what go/packages gets.
func ResolveToolchain(ctx context.Context, binary string) (*Toolchain, error) {
	if binary == "" {
		p, err := exec.LookPath("go")
		if err != nil {
			return nil, &Error{Code: pb.Error_GO_TOOLCHAIN, Err: errors.New("no `go` binary found on PATH; choose one in settings")}
		}
		binary = p
	}
	version, err := runOutput(ctx, nil, binary, "version")
	if err != nil {
		return nil, &Error{Code: pb.Error_GO_TOOLCHAIN, Err: fmt.Errorf("%s is not a usable Go binary: %w", binary, err)}
	}
	goroot, err := runOutput(ctx, nil, binary, "env", "GOROOT")
	if err != nil {
		return nil, &Error{Code: pb.Error_GO_TOOLCHAIN, Err: fmt.Errorf("%s env GOROOT: %w", binary, err)}
	}
	goroot = strings.TrimSpace(goroot)
	env := os.Environ()
	// go/packages runs "go" from PATH, so put the chosen toolchain first.
	env = append([]string{"PATH=" + filepath.Join(goroot, "bin") + string(os.PathListSeparator) + os.Getenv("PATH")}, withoutKey(env, "PATH")...)
	return &Toolchain{
		Binary:    filepath.Join(goroot, "bin", "go"),
		GOROOT:    goroot,
		GoVersion: strings.TrimSpace(version),
		Env:       env,
	}, nil
}

func withoutKey(env []string, key string) []string {
	out := env[:0:0]
	for _, kv := range env {
		if !strings.HasPrefix(kv, key+"=") {
			out = append(out, kv)
		}
	}
	return out
}

func runOutput(ctx context.Context, env []string, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if env != nil {
		cmd.Env = env
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return "", errors.New(msg)
	}
	return string(out), nil
}

// Open locates go.work or go.mod under root and lists the project's modules.
func Open(ctx context.Context, tc *Toolchain, root string, buildTags []string) (*Project, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: err}
	}
	info, err := os.Stat(abs)
	if err != nil || !info.IsDir() {
		return nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("%s is not a directory", abs)}
	}
	p := &Project{
		root:      abs,
		env:       withoutKey(tc.Env, "GOWORK"),
		goVersion: tc.GoVersion,
		meta:      map[string]*packages.Package{},
		typed:     map[string]*typedPackage{},
		inflight:  map[string]*sync.WaitGroup{},
	}
	if len(buildTags) > 0 {
		p.buildFlags = []string{"-tags=" + strings.Join(buildTags, ",")}
	}
	switch {
	case fileExists(filepath.Join(abs, "go.work")):
		p.configFile = filepath.Join(abs, "go.work")
		p.workspace = true
	case fileExists(filepath.Join(abs, "go.mod")):
		p.configFile = filepath.Join(abs, "go.mod")
	default:
		return nil, &Error{Code: pb.Error_INVALID_REQUEST, Err: fmt.Errorf("no go.work or go.mod in %s", abs)}
	}
	if !p.workspace {
		// Ignore any go.work above the chosen folder.
		p.env = append(p.env, "GOWORK=off")
	}

	// `go list -m` lists the main module, or every workspace module.
	out, err := runOutput(ctx, p.env, tc.Binary, append([]string{"-C", abs, "list", "-m", "-json"}, p.buildFlags...)...)
	if err != nil {
		return nil, &Error{Code: pb.Error_LOAD_FAILED, Err: fmt.Errorf("go list -m: %w", err)}
	}
	dec := json.NewDecoder(strings.NewReader(out))
	for {
		var m struct {
			Path, Dir, Version string
			Main               bool
		}
		if err := dec.Decode(&m); err != nil {
			break
		}
		p.modules = append(p.modules, &pb.Module{Path: m.Path, Dir: m.Dir, Version: m.Version, Main: true})
	}
	if len(p.modules) == 0 {
		return nil, &Error{Code: pb.Error_LOAD_FAILED, Err: errors.New("go list -m found no modules")}
	}
	return p, nil
}

func fileExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}

// Proto describes the project.
func (p *Project) Proto() *pb.Project {
	return &pb.Project{
		RootDir:    p.root,
		ConfigFile: p.configFile,
		Workspace:  p.workspace,
		Modules:    p.modules,
		GoVersion:  p.goVersion,
	}
}

// Root returns the project folder.
func (p *Project) Root() string { return p.root }

func (p *Project) config(ctx context.Context, mode packages.LoadMode) *packages.Config {
	return &packages.Config{
		Context:    ctx,
		Mode:       mode,
		Dir:        p.root,
		Env:        p.env,
		BuildFlags: p.buildFlags,
	}
}

func (p *Project) patterns() []string {
	pats := make([]string, 0, len(p.modules))
	for _, m := range p.modules {
		pats = append(pats, filepath.Join(m.Dir, "...")) // "dir/..." matches the module's packages
	}
	return pats
}

const metaMode = packages.NeedName | packages.NeedFiles | packages.NeedImports |
	packages.NeedDeps | packages.NeedModule

// ListPackages returns every package in the build graph. The result is
// cached until Reload invalidates it.
func (p *Project) ListPackages(ctx context.Context) (*pb.ListPackagesResponse, error) {
	p.mu.Lock()
	if p.list != nil {
		l := p.list
		p.mu.Unlock()
		return l, nil
	}
	p.mu.Unlock()

	pkgs, err := packages.Load(p.config(ctx, metaMode), p.patterns()...)
	if err != nil {
		return nil, &Error{Code: pb.Error_LOAD_FAILED, Err: err}
	}
	resp := &pb.ListPackagesResponse{}
	meta := map[string]*packages.Package{}
	mods := map[string]*pb.Module{}
	for _, m := range p.modules {
		mods[m.Path] = m
	}
	packages.Visit(pkgs, nil, func(pkg *packages.Package) {
		if isTestVariant(pkg) {
			return
		}
		if _, seen := meta[pkg.PkgPath]; seen {
			return
		}
		meta[pkg.PkgPath] = pkg
		resp.Packages = append(resp.Packages, p.packageProto(pkg))
		if pkg.Module != nil {
			if _, ok := mods[pkg.Module.Path]; !ok {
				mods[pkg.Module.Path] = &pb.Module{
					Path:    pkg.Module.Path,
					Version: pkg.Module.Version,
					Dir:     pkg.Module.Dir,
					Main:    pkg.Module.Main,
				}
			}
		}
	})
	sort.Slice(resp.Packages, func(i, j int) bool { return resp.Packages[i].ImportPath < resp.Packages[j].ImportPath })
	for _, m := range mods {
		resp.Modules = append(resp.Modules, m)
	}
	sort.Slice(resp.Modules, func(i, j int) bool {
		if resp.Modules[i].Main != resp.Modules[j].Main {
			return resp.Modules[i].Main
		}
		return resp.Modules[i].Path < resp.Modules[j].Path
	})

	p.mu.Lock()
	p.list = resp
	p.meta = meta
	p.mu.Unlock()
	return resp, nil
}

// isTestVariant reports whether pkg is a test build of a package, such as
// "fmt [fmt.test]" or "fmt_test". Only non-test builds are listed.
func isTestVariant(pkg *packages.Package) bool {
	return strings.Contains(pkg.ID, " [") || strings.HasSuffix(pkg.ID, ".test")
}

func (p *Project) packageProto(pkg *packages.Package) *pb.Package {
	out := &pb.Package{
		Id:         pkg.PkgPath,
		ImportPath: pkg.PkgPath,
		Name:       pkg.Name,
		Dir:        packageDir(pkg),
		Origin:     p.origin(pkg),
	}
	if pkg.Module != nil {
		out.ModulePath = pkg.Module.Path
		out.ModuleVersion = pkg.Module.Version
	}
	for path := range pkg.Imports {
		out.Imports = append(out.Imports, path)
	}
	sort.Strings(out.Imports)
	for _, e := range pkg.Errors {
		out.Errors = append(out.Errors, e.Error())
	}
	return out
}

func packageDir(pkg *packages.Package) string {
	if len(pkg.GoFiles) > 0 {
		return filepath.Dir(pkg.GoFiles[0])
	}
	if len(pkg.OtherFiles) > 0 {
		return filepath.Dir(pkg.OtherFiles[0])
	}
	if len(pkg.IgnoredFiles) > 0 {
		return filepath.Dir(pkg.IgnoredFiles[0])
	}
	return ""
}

func (p *Project) origin(pkg *packages.Package) pb.PackageOrigin {
	if pkg.Module == nil {
		return pb.PackageOrigin_STDLIB
	}
	for _, m := range p.modules {
		if m.Path == pkg.Module.Path && (pkg.Module.Version == "" || pkg.Module.Dir == m.Dir) {
			return pb.PackageOrigin_PROJECT
		}
	}
	return pb.PackageOrigin_DEPENDENCY
}

// Reload drops cached state for the packages that contain the changed
// files. Changes to go.mod, go.work, or the set of files in a package
// invalidate the package list too.
func (p *Project) Reload(changed []string) *pb.ReloadResponse {
	p.mu.Lock()
	defer p.mu.Unlock()
	resp := &pb.ReloadResponse{}
	affected := map[string]bool{}
	for _, f := range changed {
		f, _ = filepath.Abs(f)
		base := filepath.Base(f)
		if base == "go.mod" || base == "go.work" || base == "go.sum" || base == "go.work.sum" {
			resp.PackageListChanged = true
			continue
		}
		dir := filepath.Dir(f)
		found := false
		for path, pkg := range p.meta {
			if packageDir(pkg) != dir {
				continue
			}
			found = true
			affected[path] = true
			if !containsFile(pkg, f) {
				// A new or deleted file changes the package's file list.
				resp.PackageListChanged = true
			}
		}
		if !found && strings.HasSuffix(base, ".go") {
			// A file in a directory we have not seen: maybe a new package.
			resp.PackageListChanged = true
		}
	}
	if resp.PackageListChanged {
		p.list = nil
		p.meta = map[string]*packages.Package{}
		// Type-checked packages may depend on anything that changed.
		for path := range p.typed {
			affected[path] = true
		}
		p.typed = map[string]*typedPackage{}
	} else {
		// A changed package invalidates its reverse dependencies' types too.
		for path, tp := range p.typed {
			if affected[path] || tp.dependsOn(affected) {
				affected[path] = true
				delete(p.typed, path)
			}
		}
	}
	for path := range affected {
		resp.ChangedPackageIds = append(resp.ChangedPackageIds, path)
	}
	sort.Strings(resp.ChangedPackageIds)
	return resp
}

func containsFile(pkg *packages.Package, path string) bool {
	for _, lists := range [][]string{pkg.GoFiles, pkg.OtherFiles, pkg.IgnoredFiles} {
		for _, f := range lists {
			if f == path {
				return true
			}
		}
	}
	return false
}

// Error is a protocol error with a code.
type Error struct {
	Code pb.Error_Code
	Err  error
}

func (e *Error) Error() string { return e.Err.Error() }
func (e *Error) Unwrap() error { return e.Err }

// Proto converts any error to an Error message.
func ErrorProto(err error) *pb.Error {
	var e *Error
	if errors.As(err, &e) {
		return &pb.Error{Code: e.Code, Message: e.Err.Error()}
	}
	if errors.Is(err, context.Canceled) {
		return &pb.Error{Code: pb.Error_CANCELLED, Message: "cancelled"}
	}
	return &pb.Error{Code: pb.Error_INTERNAL, Message: err.Error()}
}
