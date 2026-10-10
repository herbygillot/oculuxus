// Package shapes has a few declarations of every kind.
package shapes

import (
	"fmt"
	"io"
)

// Kind classifies a shape.
type Kind int

const (
	// Round shapes have no corners.
	Round Kind = iota
	Square
	Other
)

// Version is the package version.
const Version = "1.0"

var (
	// Default is the default shape.
	Default Shape = Circle{Radius: 1}
	count   int
)

// Shape is anything with an area.
type Shape interface {
	fmt.Stringer
	// Area returns the area.
	Area() float64
	Kind() Kind
}

// Circle is a round shape.
type Circle struct {
	Radius float64
	center point
	point
}

type point struct{ X, Y float64 }

// Area returns the circle's area.
func (c Circle) Area() float64 { return 3 * c.Radius * c.Radius }

func (c Circle) Kind() Kind { return Round }

func (c Circle) String() string {
	r := c.Radius
	return fmt.Sprintf("circle(%v)", r)
}

// Describe writes a description of s to w.
func Describe(w io.Writer, s Shape) error {
	_, err := fmt.Fprintln(w, s.String())
	return err
}

// Pair is a generic pair.
type Pair[K comparable, V any] struct {
	Key K
	Val V
}

func (p Pair[K, V]) Swap() (V, K) { return p.Val, p.Key }
