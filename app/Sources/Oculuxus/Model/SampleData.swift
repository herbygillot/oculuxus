// Sample projects that stand in for the helper until the app talks to it.
// Everything is built from the protocol types so the views only ever see
// what the helper will send.

import Foundation

/// A project the user can pick, with the answers the helper would give.
struct SampleProject: Identifiable, Hashable {
    var id: String { rootDir }
    var name: String
    var rootDir: String
    var listing: OcxListPackagesResponse
    var outlines: [String: OcxPackageOutline]
    /// File path → source and declaration ranges.
    var files: [String: OcxFileSourceResponse]

    static func == (a: SampleProject, b: SampleProject) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    func package(_ id: String) -> OcxPackage? {
        listing.packages.first { $0.id == id }
    }

    /// The outline the helper would return, or an empty one that says
    /// there is no sample for this package.
    func outline(_ packageID: String) -> OcxPackageOutline {
        if let outline = outlines[packageID] { return outline }
        let name = package(packageID)?.name ?? packageID
        return OcxPackageOutline(packageID: packageID, name: name, doc: "There is no sample outline for this package.")
    }
}

enum SampleData {
    static let projects: [SampleProject] = [geometry(), greeter()]

    // MARK: Building blocks

    /// A declaration whose signature is found at the start of a line of
    /// `file`. Members are looked up after their parent's line.
    struct Spec {
        var kind: OcxSymbolKind
        var signature: String
        var name: String
        var members: [Spec] = []
        var embedded = false

        init(_ kind: OcxSymbolKind, _ signature: String, name: String? = nil, embedded: Bool = false, members: [Spec] = []) {
            self.kind = kind
            self.signature = signature
            self.members = members
            self.embedded = embedded
            self.name = name ?? Spec.guessName(kind, signature)
        }

        static func guessName(_ kind: OcxSymbolKind, _ signature: String) -> String {
            var s = Substring(signature)
            for prefix in ["func ", "type ", "const ", "var "] where s.hasPrefix(prefix) {
                s = s.dropFirst(prefix.count)
            }
            if s.hasPrefix("(") , let close = s.firstIndex(of: ")") {
                s = s[s.index(after: close)...].drop { $0 == " " }
            }
            return String(s.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
        }
    }

    struct PackageSpec {
        var package: OcxPackage
        var doc: String
        /// File name → source.
        var files: [(String, String)]
        /// File name → declarations in that file, in source order.
        var declarations: [(String, [Spec])]
    }

    static func build(name: String, rootDir: String, modules: [OcxModule], packages: [OcxPackage], specs: [PackageSpec]) -> SampleProject {
        // Every declared name, for highlighting references.
        var symbols: [String: [String: SampleHighlighter.Symbol]] = [:] // package name → name → symbol
        var packageIDByName: [String: String] = [:]
        for spec in specs {
            packageIDByName[spec.package.name] = spec.package.id
            var table: [String: SampleHighlighter.Symbol] = [:]
            for (_, decls) in spec.declarations {
                for decl in decls {
                    table[decl.name] = .init(type: tokenType(for: decl.kind), target: OcxSymbolRef(packageID: spec.package.id, declarationID: decl.name))
                    for member in decl.members {
                        let typeName = decl.name
                        table[typeName + "." + member.name] = .init(type: tokenType(for: member.kind), target: OcxSymbolRef(packageID: spec.package.id, declarationID: typeName + "." + member.name))
                    }
                }
            }
            symbols[spec.package.name] = table
        }
        for pkg in packages where packageIDByName[pkg.name] == nil {
            packageIDByName[pkg.name] = pkg.id
        }

        var outlines: [String: OcxPackageOutline] = [:]
        var files: [String: OcxFileSourceResponse] = [:]

        for spec in specs {
            let local = symbols[spec.package.name] ?? [:]
            let highlighter = SampleHighlighter { name, qualifier in
                if let qualifier {
                    if let table = symbols[qualifier] { return table[name] }
                    return nil
                }
                if let symbol = local[name] { return symbol }
                if let id = packageIDByName[name] {
                    return .init(type: .namespace, target: OcxSymbolRef(packageID: id))
                }
                return nil
            }

            var outline = OcxPackageOutline(packageID: spec.package.id, name: spec.package.name, doc: spec.doc)
            for (fileName, source) in spec.files {
                let path = spec.package.dir + "/" + fileName
                outline.files.append(OcxFile(path: path, name: fileName))
                let lines = source.components(separatedBy: "\n")
                let lineOffsets = lines.reduce(into: [0]) { $0.append($0.last! + $1.utf8.count + 1) }
                var response = OcxFileSourceResponse(source: highlighter.highlight(source))

                func line(of signature: String, from: Int) -> Int {
                    for i in from..<lines.count where lines[i].drop(while: { $0 == "\t" || $0 == " " }).hasPrefix(signature) {
                        return i
                    }
                    preconditionFailure("sample signature not found in \(fileName): \(signature)")
                }

                // The extent of a top-level declaration: from its doc
                // comment to the line before the next blank line at the top level.
                func range(startLine: Int) -> OcxRange {
                    var first = startLine
                    while first > 0, lines[first - 1].hasPrefix("//") { first -= 1 }
                    var last = startLine
                    if lines[startLine].hasSuffix("{") || lines[startLine].hasSuffix("(") {
                        while last + 1 < lines.count, !(lines[last] == "}" || lines[last] == ")") { last += 1 }
                    }
                    return OcxRange(start: UInt32(lineOffsets[first]), end: UInt32(lineOffsets[last] + lines[last].utf8.count))
                }

                func declaration(_ s: Spec, parent: String?, from: Int) -> (OcxDeclaration, Int) {
                    let lineIndex = line(of: s.signature, from: from)
                    let id = parent.map { $0 + "." + s.name } ?? s.name
                    let docLines = lines[..<lineIndex].reversed().prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    let doc = docLines.reversed().map { $0.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                    var d = OcxDeclaration(
                        id: id, kind: s.kind, name: s.name,
                        exported: s.name.first?.isUppercase ?? false,
                        signature: highlighter.highlight(s.signature),
                        doc: doc,
                        location: OcxLocation(file: path, line: UInt32(lineIndex + 1), column: 1),
                        embedded: s.embedded
                    )
                    if parent == nil {
                        response.declarations.append(OcxDeclarationRange(declarationID: id, range: range(startLine: lineIndex)))
                    } else {
                        let start = UInt32(lineOffsets[lineIndex])
                        response.declarations.append(OcxDeclarationRange(declarationID: id, range: OcxRange(start: start, end: start + UInt32(lines[lineIndex].utf8.count))))
                    }
                    var cursor = lineIndex + 1
                    for member in s.members {
                        // Methods are declared after the type, anywhere in the file.
                        let searchFrom = member.kind == .method && s.kind != .interface ? lineIndex + 1 : cursor
                        let (m, memberLine) = declaration(member, parent: s.name, from: searchFrom)
                        d.members.append(m)
                        if member.kind != .method || s.kind == .interface { cursor = memberLine + 1 }
                    }
                    return (d, lineIndex)
                }

                for (declFile, decls) in spec.declarations where declFile == fileName {
                    for s in decls {
                        outline.declarations.append(declaration(s, parent: nil, from: 0).0)
                    }
                }
                files[path] = response
            }
            outlines[spec.package.id] = outline
        }

        return SampleProject(
            name: name, rootDir: rootDir,
            listing: OcxListPackagesResponse(packages: packages, modules: modules),
            outlines: outlines, files: files
        )
    }

    static func tokenType(for kind: OcxSymbolKind) -> OcxTokenType {
        switch kind {
        case .const: .constant
        case .var: .variable
        case .func: .function
        case .method: .methodName
        case .struct: .structName
        case .interface: .interfaceName
        case .type: .typeName
        case .field: .property
        case .unspecified: .unspecified
        }
    }

    static func stdlib(_ path: String) -> OcxPackage {
        OcxPackage(id: path, importPath: path, name: String(path.split(separator: "/").last!), dir: "/usr/local/go/src/" + path, origin: .stdlib)
    }

    static func dependency(_ path: String, module: OcxModule) -> OcxPackage {
        OcxPackage(
            id: path, importPath: path, name: String(path.split(separator: "/").last!),
            dir: module.dir + path.dropFirst(module.path.count), origin: .dependency,
            modulePath: module.path, moduleVersion: module.version
        )
    }

    // MARK: Projects

    static func geometry() -> SampleProject {
        let root = "/Users/gopher/src/geometry"
        let main = OcxModule(path: "github.com/example/geometry", dir: root, main: true)
        let color = OcxModule(path: "github.com/fatih/color", version: "v1.18.0", dir: "/Users/gopher/go/pkg/mod/github.com/fatih/color@v1.18.0")
        let isatty = OcxModule(path: "github.com/mattn/go-isatty", version: "v0.0.20", dir: "/Users/gopher/go/pkg/mod/github.com/mattn/go-isatty@v0.0.20")
        let exp = OcxModule(path: "golang.org/x/exp", version: "v0.0.0-20250911091902-df9299821621", dir: "/Users/gopher/go/pkg/mod/golang.org/x/exp@v0.0.0-20250911091902-df9299821621")

        func own(_ path: String) -> OcxPackage {
            OcxPackage(id: path, importPath: path, name: String(path.split(separator: "/").last!), dir: root + path.dropFirst(main.path.count), origin: .project, modulePath: main.path)
        }
        let geometryPkg = own("github.com/example/geometry")
        let renderPkg = own("github.com/example/geometry/render")
        let unitsPkg = own("github.com/example/geometry/internal/units")
        let colorPkg = dependency("github.com/fatih/color", module: color)
        let ioPkg = stdlib("io")
        let mathPkg = stdlib("math")

        let packages: [OcxPackage] = [
            geometryPkg, renderPkg, unitsPkg,
            colorPkg,
            dependency("github.com/mattn/go-isatty", module: isatty),
            dependency("golang.org/x/exp/constraints", module: exp),
            dependency("golang.org/x/exp/slices", module: exp),
            stdlib("errors"), stdlib("fmt"), ioPkg, mathPkg, stdlib("math/bits"),
            stdlib("os"), stdlib("strconv"), stdlib("strings"), stdlib("sync"), stdlib("unicode/utf8"),
        ]

        let specs = [
            PackageSpec(
                package: geometryPkg,
                doc: """
                Package geometry provides basic two-dimensional shapes and the operations common to all of them.

                Every shape implements Shape, so code that draws or measures shapes does not need to know which kind it has.
                """,
                files: [("shapes.go", SampleSources.geometryShapes), ("point.go", SampleSources.geometryPoint)],
                declarations: [
                    ("shapes.go", [
                        Spec(.const, "const DefaultPrecision = 2"),
                        Spec(.const, "const maxSides = 64"),
                        Spec(.var, "var ErrNegative = errors.New(\"geometry: negative dimension\")"),
                        Spec(.var, "var registry = map[string]func() Shape{}"),
                        Spec(.interface, "type Shape interface", members: [
                            Spec(.method, "Area() float64"),
                            Spec(.method, "Perimeter() float64"),
                            Spec(.type, "fmt.Stringer", name: "Stringer", embedded: true),
                        ]),
                        Spec(.struct, "type Circle struct", members: [
                            Spec(.field, "Center Point"),
                            Spec(.field, "Radius float64"),
                            Spec(.method, "func (c *Circle) Area() float64"),
                            Spec(.method, "func (c *Circle) Perimeter() float64"),
                            Spec(.method, "func (c *Circle) String() string"),
                        ]),
                        Spec(.func, "func NewCircle(center Point, r float64) (*Circle, error)"),
                        Spec(.struct, "type Polygon struct", members: [
                            Spec(.field, "Vertices []Point"),
                            Spec(.field, "closed   bool"),
                            Spec(.method, "func (p *Polygon) Area() float64"),
                            Spec(.method, "func (p *Polygon) Perimeter() float64"),
                            Spec(.method, "func (p *Polygon) String() string"),
                            Spec(.method, "func (p *Polygon) validate() error"),
                        ]),
                        Spec(.type, "type Units int"),
                        Spec(.func, "func Register(name string, ctor func() Shape)"),
                        Spec(.func, "func TotalArea(shapes ...Shape) float64"),
                        Spec(.func, "func round(x float64, places int) float64"),
                    ]),
                    ("point.go", [
                        Spec(.var, "var Origin = Point{}"),
                        Spec(.struct, "type Point struct", members: [
                            Spec(.field, "X float64"),
                            Spec(.field, "Y float64"),
                            Spec(.method, "func (p Point) Distance(q Point) float64"),
                            Spec(.method, "func (p Point) Add(q Point) Point"),
                        ]),
                    ]),
                ]
            ),
            PackageSpec(
                package: renderPkg,
                doc: "Package render draws shapes as SVG.",
                files: [("svg.go", SampleSources.renderSVG)],
                declarations: [("svg.go", [
                    Spec(.struct, "type Options struct", members: [
                        Spec(.field, "Stroke string"),
                        Spec(.field, "Fill   string"),
                        Spec(.field, "Width  float64"),
                    ]),
                    Spec(.var, "var DefaultOptions = Options{Stroke: \"black\", Fill: \"none\", Width: 1}"),
                    Spec(.struct, "type Renderer struct", members: [
                        Spec(.field, "w    io.Writer"),
                        Spec(.field, "opts Options"),
                        Spec(.method, "func (r *Renderer) Draw(s geometry.Shape) error"),
                    ]),
                    Spec(.func, "func New(w io.Writer, opts Options) *Renderer"),
                    Spec(.func, "func Debug(s geometry.Shape)"),
                ])]
            ),
            PackageSpec(
                package: unitsPkg,
                doc: "Package units converts between length units.",
                files: [("units.go", SampleSources.unitsUnits)],
                declarations: [("units.go", [
                    Spec(.const, "Millimetre = 1.0"),
                    Spec(.const, "Centimetre = 10 * Millimetre"),
                    Spec(.const, "Inch       = 25.4 * Millimetre"),
                    Spec(.func, "func Convert(v, from, to float64) float64"),
                ])]
            ),
            PackageSpec(
                package: colorPkg,
                doc: "Package color is an ANSI color package to output colorized or SGR defined output to the standard output.",
                files: [("color.go", SampleSources.colorColor)],
                declarations: [("color.go", [
                    Spec(.var, "var NoColor = false"),
                    Spec(.var, "var Output io.Writer"),
                    Spec(.type, "type Attribute int"),
                    Spec(.struct, "type Color struct", members: [
                        Spec(.field, "params  []Attribute"),
                        Spec(.field, "noColor *bool"),
                        Spec(.method, "func (c *Color) Printf(format string, a ...interface{}) (n int, err error)"),
                    ]),
                    Spec(.func, "func New(value ...Attribute) *Color"),
                    Spec(.func, "func Cyan(format string, a ...interface{})"),
                ])]
            ),
            PackageSpec(
                package: ioPkg,
                doc: "Package io provides basic interfaces to I/O primitives.",
                files: [("io.go", SampleSources.ioIO)],
                declarations: [("io.go", [
                    Spec(.var, "var EOF = errors.New(\"EOF\")"),
                    Spec(.const, "const SeekStart = 0"),
                    Spec(.interface, "type Reader interface", members: [Spec(.method, "Read(p []byte) (n int, err error)")]),
                    Spec(.interface, "type Writer interface", members: [Spec(.method, "Write(p []byte) (n int, err error)")]),
                    Spec(.interface, "type ReadWriter interface", members: [
                        Spec(.type, "Reader", embedded: true),
                        Spec(.type, "Writer", embedded: true),
                    ]),
                    Spec(.func, "func Copy(dst Writer, src Reader) (written int64, err error)"),
                ])]
            ),
            PackageSpec(
                package: mathPkg,
                doc: "Package math provides basic constants and mathematical functions.",
                files: [("math.go", SampleSources.mathConst)],
                declarations: [("math.go", [
                    Spec(.const, "const Pi = 3.14159265358979323846264338327950288419716939937510582097494459"),
                    Spec(.func, "func Abs(x float64) float64"),
                    Spec(.func, "func Hypot(p, q float64) float64"),
                ])]
            ),
        ]

        return build(name: "geometry", rootDir: root, modules: [main, color, isatty, exp], packages: packages, specs: specs)
    }

    static func greeter() -> SampleProject {
        let root = "/Users/gopher/src/greeter"
        let main = OcxModule(path: "example.com/greeter", dir: root, main: true)
        let pkg = OcxPackage(id: main.path, importPath: main.path, name: "greeter", dir: root, origin: .project, modulePath: main.path)
        let spec = PackageSpec(
            package: pkg,
            doc: "Package greeter says hello.",
            files: [("greeter.go", SampleSources.greeter)],
            declarations: [("greeter.go", [
                Spec(.const, "const Greeting = \"Hello\""),
                Spec(.struct, "type Greeter struct", members: [
                    Spec(.field, "Name string"),
                    Spec(.method, "func (g Greeter) Greet() string"),
                ]),
            ])]
        )
        return build(name: "greeter", rootDir: root, modules: [main], packages: [pkg, stdlib("fmt")], specs: [spec])
    }
}
