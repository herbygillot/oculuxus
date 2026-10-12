// Plain Swift mirrors of the messages in proto/oculuxus/v1/oculuxus.proto
// that the UI needs. Names and shapes follow what the swift-protobuf
// generator produces for that file (swift_prefix "Ocx", camelCase fields,
// non-optional message fields with a `hasX` flag), so that step 3 can
// replace this file with the generated code without touching the views.

import Foundation

enum OcxPackageOrigin: Int, Hashable, Sendable {
    case unspecified = 0
    case project = 1
    case dependency = 2
    case stdlib = 3
}

struct OcxModule: Hashable, Sendable {
    var path = ""
    var version = ""
    var dir = ""
    var main = false
}

struct OcxPackage: Hashable, Identifiable, Sendable {
    var id = ""
    var importPath = ""
    var name = ""
    var dir = ""
    var origin: OcxPackageOrigin = .unspecified
    var modulePath = ""
    var moduleVersion = ""
    var imports: [String] = []
    var errors: [String] = []
}

struct OcxListPackagesResponse: Sendable {
    var packages: [OcxPackage] = []
    var modules: [OcxModule] = []
}

struct OcxFile: Hashable, Sendable {
    var path = ""
    var name = ""
}

enum OcxSymbolKind: Int, Hashable, Sendable {
    case unspecified = 0
    case const = 1
    case `var` = 2
    case `func` = 3
    case method = 4
    case `struct` = 5
    case interface = 6
    case type = 7
    case field = 8
}

struct OcxLocation: Hashable, Sendable {
    var file = ""
    var line: UInt32 = 0
    var column: UInt32 = 0
}

struct OcxRange: Hashable, Sendable {
    var start: UInt32 = 0
    var end: UInt32 = 0
}

enum OcxTokenType: Int, Hashable, Sendable {
    case unspecified = 0
    case keyword = 1
    case comment = 2
    case string = 3
    case number = 4
    case `operator` = 5
    case namespace = 6
    case typeName = 7
    case structName = 8
    case interfaceName = 9
    case typeParameter = 10
    case function = 11
    case methodName = 12
    case variable = 13
    case parameter = 14
    case property = 15
    case constant = 16
    case label = 17
    case builtin = 18
}

/// Bit values for `OcxToken.modifiers`.
enum OcxTokenModifier: UInt32, Sendable {
    case none = 0
    case definition = 1
    case exported = 2
    case documentation = 4
}

struct OcxSymbolRef: Hashable, Sendable {
    var packageID = ""
    var declarationID = ""
}

struct OcxToken: Hashable, Sendable {
    var range = OcxRange()
    var type: OcxTokenType = .unspecified
    var modifiers: UInt32 = 0
    var target = OcxSymbolRef() { didSet { hasTarget = true } }
    private(set) var hasTarget = false

    init(range: OcxRange = OcxRange(), type: OcxTokenType = .unspecified, modifiers: UInt32 = 0, target: OcxSymbolRef? = nil) {
        self.range = range
        self.type = type
        self.modifiers = modifiers
        if let target {
            self.target = target
            self.hasTarget = true
        }
    }
}

/// Highlighted text. Token ranges are UTF-8 byte offsets into `text`.
struct OcxText: Hashable, Sendable {
    var text = ""
    var tokens: [OcxToken] = []
}

struct OcxDeclaration: Hashable, Identifiable, Sendable {
    var id = ""
    var kind: OcxSymbolKind = .unspecified
    var name = ""
    var exported = false
    var signature = OcxText()
    var doc = ""
    var location = OcxLocation()
    var members: [OcxDeclaration] = []
    var embedded = false
}

struct OcxPackageOutline: Hashable, Sendable {
    var packageID = ""
    var name = ""
    var doc = ""
    var files: [OcxFile] = []
    var declarations: [OcxDeclaration] = []
    var errors: [String] = []
}

struct OcxDeclarationRange: Hashable, Sendable {
    var declarationID = ""
    var range = OcxRange()
}

struct OcxFileSourceResponse: Hashable, Sendable {
    var source = OcxText()
    var declarations: [OcxDeclarationRange] = []
}
