// Package draw uses shapes, for reference and call hierarchy tests.
package draw

import (
	"io"
	"os"

	"example.com/simple/shapes"
)

// Unit is a circle of radius one.
var Unit = shapes.Circle{Radius: 1}

// Total adds up the areas of the shapes.
func Total(ss []shapes.Shape) float64 {
	sum := 0.0
	for _, s := range ss {
		sum += s.Area()
	}
	return sum
}

// Print describes the unit circle and the default shape.
func Print(w io.Writer) error {
	if err := shapes.Describe(w, Unit); err != nil {
		return err
	}
	c := Unit
	c.Scale(2)
	area := c.Area() + shapes.Default.Area()
	report := func(float64) {}
	report(area)
	return shapes.Describe(os.Stdout, c)
}
