package analysis

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	pb "github.com/herbygillot/oculuxus/helper/pb/oculuxus/v1"
)

// Search finds declarations whose names match the query, best first. It
// lists packages first if needed, which starts the index, then waits for
// the project's packages to be indexed, reporting progress. Dependencies
// are searched as far as they are indexed unless req.Wait is set.
func (p *Project) Search(ctx context.Context, req *pb.SearchRequest, progress func(string)) (*pb.SearchResponse, error) {
	if _, err := p.ListPackages(ctx); err != nil {
		return nil, err
	}
	deps := req.IncludeDependencies
	var pkgs []*indexedPkg
	var st indexStatus
	lastReport := time.Time{}
	for {
		var changed <-chan struct{}
		pkgs, st, changed = p.index.snapshot(deps)
		_, project, _ := p.index.snapshot(false)
		if st.complete() || (!req.Wait && project.complete()) {
			break
		}
		if time.Since(lastReport) > 100*time.Millisecond {
			progress(indexProgress(st))
			lastReport = time.Now()
		}
		select {
		case <-changed:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	limit := int(req.Limit)
	if limit <= 0 {
		limit = 50
	}
	return &pb.SearchResponse{
		Matches:         search(pkgs, req.Query, limit),
		Complete:        st.complete(),
		IndexedPackages: uint32(st.indexed),
		TotalPackages:   uint32(st.total),
	}, nil
}

func indexProgress(st indexStatus) string {
	return fmt.Sprintf("Indexing %d of %d packages", st.indexed, st.total)
}

// searchQuery is a query, split for matching. "Server", "server.serve",
// "http.Server" and "net/http" all work: a query with a dot matches
// "Type.Member" and "pkg.Name"; one with a slash matches import paths.
type searchQuery struct {
	raw   string
	lower string
	dot   bool
	slash bool
}

type scored struct {
	match *pb.SymbolMatch
	score int
}

func search(pkgs []*indexedPkg, query string, limit int) []*pb.SymbolMatch {
	query = strings.Join(strings.Fields(query), "")
	if query == "" {
		return nil
	}
	q := searchQuery{
		raw:   query,
		lower: strings.ToLower(query),
		dot:   strings.Contains(query, "."),
		slash: strings.Contains(query, "/"),
	}
	var results []scored
	for _, ip := range pkgs {
		t := ip.target
		if score, ranges := matchPackage(q, t); score > 0 {
			results = append(results, scored{score: score, match: &pb.SymbolMatch{
				PackageId: t.id, PackageName: t.name, Kind: pb.SymbolKind_PACKAGE,
				Signature: "package " + t.name, Origin: t.origin, Matched: ranges,
			}})
		}
		if q.slash {
			continue
		}
		for i := range ip.symbols {
			s := &ip.symbols[i]
			score, ranges := matchSymbol(q, t.name, s)
			if score <= 0 {
				continue
			}
			score += symbolBonus(s, t.origin)
			m := &pb.SymbolMatch{
				PackageId: t.id, PackageName: t.name, DeclarationId: s.id,
				Kind: s.kind, Signature: s.signature, Origin: t.origin, Matched: ranges,
			}
			if int(s.file) < len(ip.files) {
				m.Location = &pb.Location{File: ip.files[s.file], Line: s.line, Column: s.column}
			}
			results = append(results, scored{score: score, match: m})
		}
	}
	sort.Slice(results, func(i, j int) bool {
		a, b := results[i], results[j]
		if a.score != b.score {
			return a.score > b.score
		}
		if a.match.DeclarationId != b.match.DeclarationId {
			return a.match.DeclarationId < b.match.DeclarationId
		}
		return a.match.PackageId < b.match.PackageId
	})
	if len(results) > limit {
		results = results[:limit]
	}
	out := make([]*pb.SymbolMatch, len(results))
	for i, r := range results {
		out[i] = r.match
	}
	return out
}

// matchSymbol scores a symbol against the query. Without a dot the query
// matches the symbol's own name; with one it matches "Type.Member" or
// "pkg.Type.Member". Ranges are into the declaration id.
func matchSymbol(q searchQuery, pkgName string, s *indexedSymbol) (int, []*pb.Range) {
	if !q.dot {
		off := len(s.id) - len(s.name)
		score, ranges := matchText(q, s.name, s.lowerID[off:])
		if score == 0 && off > 0 {
			// "pswap" for Pair.Swap: fuzzy across the type and member.
			return fuzzy(q, s.id, s.lowerID)
		}
		return score, shift(ranges, off)
	}
	score, ranges := matchText(q, s.id, s.lowerID)
	qualified := pkgName + "." + s.id
	if qs, qr := matchText(q, qualified, strings.ToLower(qualified)); qs > score {
		score, ranges = qs, shift(qr, -(len(pkgName)+1))
	}
	return score, ranges
}

// matchPackage scores a package by name, or by import path when the
// query has a slash. Ranges are into the package id.
func matchPackage(q searchQuery, t indexTarget) (int, []*pb.Range) {
	if q.dot {
		return 0, nil
	}
	if q.slash {
		score, ranges := matchText(q, t.id, strings.ToLower(t.id))
		if score > 0 {
			score += originBonus(t.origin) + 40 - len(t.id)/4
		}
		return score, ranges
	}
	score, ranges := matchText(q, t.name, strings.ToLower(t.name))
	if score <= 0 {
		return 0, nil
	}
	score += originBonus(t.origin) + 40
	if !strings.HasSuffix(t.id, t.name) {
		return score, nil // the name is not the last path element
	}
	return score, shift(ranges, len(t.id)-len(t.name))
}

func symbolBonus(s *indexedSymbol, origin pb.PackageOrigin) int {
	bonus := originBonus(origin) - len(s.name)/2
	switch s.kind {
	case pb.SymbolKind_STRUCT, pb.SymbolKind_INTERFACE, pb.SymbolKind_TYPE:
		bonus += 40
	case pb.SymbolKind_FUNC:
		bonus += 35
	case pb.SymbolKind_METHOD:
		bonus += 25
	case pb.SymbolKind_CONST, pb.SymbolKind_VAR:
		bonus += 15
	}
	if exported(s.name) {
		bonus += 30
	}
	return bonus
}

func originBonus(o pb.PackageOrigin) int {
	switch o {
	case pb.PackageOrigin_PROJECT:
		return 120
	case pb.PackageOrigin_STDLIB:
		return 20
	}
	return 0
}

// Match tiers. Bonuses stay well below the gaps between them, so a better
// kind of match wins over a better kind of symbol, except that the
// project's own symbols can climb one tier.
const (
	tierExact     = 1000
	tierPrefix    = 800
	tierWordStart = 600
	tierSubstring = 450
	tierFuzzy     = 150
	caseBonus     = 50
)

// matchText matches the query against text (lower is its lowercase
// form, the same length since Go identifiers here are ASCII-dominated;
// non-ASCII text falls back to byte-wise matching of the lowercase form).
func matchText(q searchQuery, text, lower string) (int, []*pb.Range) {
	if len(lower) != len(text) {
		text = lower
	}
	n := len(q.lower)
	switch {
	case lower == q.lower:
		score := tierExact
		if text == q.raw {
			score += caseBonus
		}
		return score, []*pb.Range{{Start: 0, End: uint32(n)}}
	case strings.HasPrefix(lower, q.lower):
		score := tierPrefix - (len(lower) - n)
		if strings.HasPrefix(text, q.raw) {
			score += caseBonus
		}
		return score, []*pb.Range{{Start: 0, End: uint32(n)}}
	}
	first := -1
	for i := strings.Index(lower, q.lower); i >= 0; {
		if first < 0 {
			first = i
		}
		if wordStart(text, i) {
			score := tierWordStart - i
			if text[i:i+n] == q.raw {
				score += caseBonus
			}
			return score, []*pb.Range{{Start: uint32(i), End: uint32(i + n)}}
		}
		j := strings.Index(lower[i+1:], q.lower)
		if j < 0 {
			break
		}
		i += 1 + j
	}
	if first >= 0 {
		return tierSubstring - first, []*pb.Range{{Start: uint32(first), End: uint32(first + n)}}
	}
	return fuzzy(q, text, lower)
}

// fuzzy matches the query's characters in order, preferring runs of
// adjacent characters and the starts of words, so "las" finds
// ListenAndServe and "srvmux" finds ServeMux. The first character must
// start a word, which keeps out most accidental matches.
func fuzzy(q searchQuery, text, lower string) (int, []*pb.Range) {
	if len(q.lower) < 2 {
		return 0, nil
	}
	pos := 0
	prev := -2
	score := tierFuzzy
	var ranges []*pb.Range
	for k := 0; k < len(q.lower); k++ {
		c := q.lower[k]
		found := -1
		// Prefer the next character if it continues a run, then the next
		// word start, then any occurrence.
		if prev >= 0 && prev+1 < len(lower) && lower[prev+1] == c {
			found = prev + 1
		} else {
			for i := pos; i < len(lower); i++ {
				if lower[i] == c && wordStart(text, i) {
					found = i
					break
				}
			}
			if found < 0 && k > 0 {
				if i := strings.IndexByte(lower[pos:], c); i >= 0 {
					found = pos + i
				}
			}
		}
		if found < 0 {
			return 0, nil
		}
		switch {
		case found == prev+1:
			score += 6
		case wordStart(text, found):
			score += 10
		default:
			score -= 4
		}
		score -= found - pos // skipped characters
		if found == prev+1 && len(ranges) > 0 {
			ranges[len(ranges)-1].End++
		} else {
			ranges = append(ranges, &pb.Range{Start: uint32(found), End: uint32(found + 1)})
		}
		prev = found
		pos = found + 1
	}
	if score < 1 {
		score = 1
	}
	return min(score, tierSubstring-1), ranges
}

// wordStart reports whether a word starts at byte i of an identifier:
// the first character, an upper-case letter after a lower-case one, the
// last capital of an acronym before a lower-case letter ("HTTPServer"),
// a letter after an underscore, dot or digit, or a digit after a letter.
func wordStart(s string, i int) bool {
	if i == 0 {
		return true
	}
	r, _ := utf8.DecodeRuneInString(s[i:])
	p, _ := utf8.DecodeLastRuneInString(s[:i])
	switch {
	case p == '_' || p == '.' || p == '/':
		return r != '_'
	case unicode.IsUpper(r) && !unicode.IsUpper(p):
		return true
	case unicode.IsUpper(r) && unicode.IsUpper(p):
		next, _ := utf8.DecodeRuneInString(s[i+utf8.RuneLen(r):])
		return i+utf8.RuneLen(r) < len(s) && unicode.IsLower(next)
	case unicode.IsDigit(r) != unicode.IsDigit(p):
		return true
	}
	return false
}

// shift moves ranges by off and drops what falls before zero.
func shift(ranges []*pb.Range, off int) []*pb.Range {
	if off == 0 {
		return ranges
	}
	out := ranges[:0]
	for _, r := range ranges {
		start, end := int(r.Start)+off, int(r.End)+off
		if end <= 0 {
			continue
		}
		out = append(out, &pb.Range{Start: uint32(max(start, 0)), End: uint32(end)})
	}
	return out
}
