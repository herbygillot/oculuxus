// Go source used by the sample data. Each declaration listed in
// SampleData.swift must appear here at the start of a line.

enum SampleSources {
    static let geometryShapes = """
    // Package geometry provides basic two-dimensional shapes and the
    // operations common to all of them.
    //
    // Every shape implements Shape, so code that draws or measures shapes
    // does not need to know which kind it has.
    package geometry

    import (
    \t"errors"
    \t"fmt"
    \t"math"
    )

    // DefaultPrecision is the number of decimal places used by String methods.
    const DefaultPrecision = 2

    const maxSides = 64

    // ErrNegative is returned when a dimension is negative.
    var ErrNegative = errors.New("geometry: negative dimension")

    var registry = map[string]func() Shape{}

    // Shape is a closed two-dimensional figure.
    type Shape interface {
    \t// Area returns the area enclosed by the shape.
    \tArea() float64
    \t// Perimeter returns the length of the shape's boundary.
    \tPerimeter() float64
    \tfmt.Stringer
    }

    // Circle is a circle with its center at Center.
    type Circle struct {
    \tCenter Point
    \tRadius float64
    }

    // NewCircle returns a circle, or ErrNegative if r is negative.
    func NewCircle(center Point, r float64) (*Circle, error) {
    \tif r < 0 {
    \t\treturn nil, ErrNegative
    \t}
    \treturn &Circle{Center: center, Radius: r}, nil
    }

    // Area returns πr².
    func (c *Circle) Area() float64 {
    \treturn math.Pi * c.Radius * c.Radius
    }

    // Perimeter returns 2πr.
    func (c *Circle) Perimeter() float64 {
    \treturn 2 * math.Pi * c.Radius
    }

    func (c *Circle) String() string {
    \treturn fmt.Sprintf("circle(%v, r=%.*f)", c.Center, DefaultPrecision, c.Radius)
    }

    // Polygon is a closed shape made of straight sides.
    type Polygon struct {
    \tVertices []Point
    \tclosed   bool
    }

    // Area uses the shoelace formula.
    func (p *Polygon) Area() float64 {
    \tvar sum float64
    \tfor i, a := range p.Vertices {
    \t\tb := p.Vertices[(i+1)%len(p.Vertices)]
    \t\tsum += a.X*b.Y - b.X*a.Y
    \t}
    \treturn math.Abs(sum) / 2
    }

    func (p *Polygon) Perimeter() float64 {
    \tvar total float64
    \tfor i, a := range p.Vertices {
    \t\ttotal += a.Distance(p.Vertices[(i+1)%len(p.Vertices)])
    \t}
    \treturn total
    }

    func (p *Polygon) String() string {
    \treturn fmt.Sprintf("polygon(%d sides)", len(p.Vertices))
    }

    func (p *Polygon) validate() error {
    \tif len(p.Vertices) > maxSides {
    \t\treturn errors.New("geometry: too many sides")
    \t}
    \treturn nil
    }

    // Units is a length unit.
    type Units int

    // Register adds a constructor for a named shape.
    func Register(name string, ctor func() Shape) {
    \tregistry[name] = ctor
    }

    // TotalArea returns the sum of the areas of shapes.
    func TotalArea(shapes ...Shape) float64 {
    \tvar total float64
    \tfor _, s := range shapes {
    \t\ttotal += s.Area()
    \t}
    \treturn total
    }

    func round(x float64, places int) float64 {
    \tp := math.Pow(10, float64(places))
    \treturn math.Round(x*p) / p
    }

    """

    static let geometryPoint = """
    package geometry

    import "math"

    // Origin is the point (0, 0).
    var Origin = Point{}

    // Point is a position in the plane.
    type Point struct {
    \tX float64
    \tY float64
    }

    // Distance returns the Euclidean distance between p and q.
    func (p Point) Distance(q Point) float64 {
    \treturn math.Hypot(q.X-p.X, q.Y-p.Y)
    }

    // Add returns p translated by q.
    func (p Point) Add(q Point) Point {
    \treturn Point{p.X + q.X, p.Y + q.Y}
    }

    """

    static let renderSVG = """
    // Package render draws shapes as SVG.
    package render

    import (
    \t"fmt"
    \t"io"

    \t"github.com/example/geometry"
    \t"github.com/fatih/color"
    )

    // Options controls how shapes are drawn.
    type Options struct {
    \tStroke string
    \tFill   string
    \tWidth  float64
    }

    // DefaultOptions draws black outlines with no fill.
    var DefaultOptions = Options{Stroke: "black", Fill: "none", Width: 1}

    // Renderer writes SVG to an io.Writer.
    type Renderer struct {
    \tw    io.Writer
    \topts Options
    }

    // New returns a Renderer that writes to w.
    func New(w io.Writer, opts Options) *Renderer {
    \treturn &Renderer{w: w, opts: opts}
    }

    // Draw writes one SVG element for s.
    func (r *Renderer) Draw(s geometry.Shape) error {
    \t_, err := fmt.Fprintf(r.w, "<!-- %v -->\\n", s)
    \treturn err
    }

    // Debug prints a coloured summary of s to standard output.
    func Debug(s geometry.Shape) {
    \tcolor.Cyan("%v has area %.2f", s, s.Area())
    }

    """

    static let unitsUnits = """
    // Package units converts between length units.
    package units

    // Per-unit lengths in millimetres.
    const (
    \tMillimetre = 1.0
    \tCentimetre = 10 * Millimetre
    \tInch       = 25.4 * Millimetre
    )

    // Convert converts v from one unit to another.
    func Convert(v, from, to float64) float64 {
    \treturn v * from / to
    }

    """

    static let colorColor = """
    // Package color is an ANSI color package to output colorized or SGR
    // defined output to the standard output.
    package color

    import "io"

    // NoColor defines if the output is colorized or not.
    var NoColor = false

    // Output defines the standard output of the print functions.
    var Output io.Writer

    // Attribute defines a single SGR Code.
    type Attribute int

    // Color defines a custom color object which is defined by SGR parameters.
    type Color struct {
    \tparams  []Attribute
    \tnoColor *bool
    }

    // New returns a newly created color object.
    func New(value ...Attribute) *Color {
    \treturn &Color{params: value}
    }

    // Printf formats according to a format specifier and writes to Output.
    func (c *Color) Printf(format string, a ...interface{}) (n int, err error) {
    \treturn 0, nil
    }

    // Cyan is a convenient helper function to print with cyan foreground.
    func Cyan(format string, a ...interface{}) {
    }

    """

    static let ioIO = """
    // Package io provides basic interfaces to I/O primitives.
    package io

    // EOF is the error returned by Read when no more input is available.
    var EOF = errors.New("EOF")

    // Seek whence values.
    const SeekStart = 0

    // Reader is the interface that wraps the basic Read method.
    type Reader interface {
    \tRead(p []byte) (n int, err error)
    }

    // Writer is the interface that wraps the basic Write method.
    type Writer interface {
    \tWrite(p []byte) (n int, err error)
    }

    // ReadWriter is the interface that groups the basic Read and Write methods.
    type ReadWriter interface {
    \tReader
    \tWriter
    }

    // Copy copies from src to dst until either EOF is reached on src or an
    // error occurs.
    func Copy(dst Writer, src Reader) (written int64, err error) {
    \treturn copyBuffer(dst, src, nil)
    }

    """

    static let mathConst = """
    // Package math provides basic constants and mathematical functions.
    package math

    // Mathematical constants.
    const Pi = 3.14159265358979323846264338327950288419716939937510582097494459

    // Abs returns the absolute value of x.
    func Abs(x float64) float64 {
    \treturn Float64frombits(Float64bits(x) &^ (1 << 63))
    }

    // Hypot returns Sqrt(p*p + q*q), taking care to avoid unnecessary
    // overflow and underflow.
    func Hypot(p, q float64) float64 {
    \treturn hypot(p, q)
    }

    """

    static let greeter = """
    // Package greeter says hello.
    package greeter

    import "fmt"

    // Greeting is the word used to greet.
    const Greeting = "Hello"

    // Greeter greets people by name.
    type Greeter struct {
    \tName string
    }

    // Greet returns a greeting for g.Name.
    func (g Greeter) Greet() string {
    \treturn fmt.Sprintf("%s, %s!", Greeting, g.Name)
    }

    """
}
