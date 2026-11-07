// A small reader for ASL disassembled by `iasl -dl` (legacy syntax, so every
// table looks the same whatever the user's dump tool produced). It collects
// what the vendor profiles need: devices, methods with their bodies, names,
// mutexes, operation regions and field units with their bit offsets.
//
// Paths are stored with each segment padded to 4 characters, the way ACPI
// stores them ("\_SB_.PCI0.LPCB.EC__").

import Foundation

struct ACPIPath: Hashable, CustomStringConvertible {
    var segs: [String]

    static let root = ACPIPath(segs: [])

    static func pad(_ s: String) -> String { s.count >= 4 ? s : s + String(repeating: "_", count: 4 - s.count) }

    var parent: ACPIPath { ACPIPath(segs: Array(segs.dropLast())) }
    var last: String { segs.last ?? "" }
    func child(_ n: String) -> ACPIPath { ACPIPath(segs: segs + [ACPIPath.pad(n)]) }

    // Resolve a name string from ASL relative to `scope`.
    static func resolve(_ raw: String, in scope: ACPIPath) -> ACPIPath {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        var base = scope
        if s.hasPrefix("\\") { base = .root; s = s.dropFirst() }
        while s.hasPrefix("^") { base = base.parent; s = s.dropFirst() }
        let parts = s.split(separator: ".").map { pad(String($0)) }
        return ACPIPath(segs: base.segs + parts)
    }

    // "\_SB_.PCI0.EC__"
    var description: String { "\\" + segs.joined(separator: ".") }

    // "\_SB.PCI0.EC" for templates and README text.
    var short: String {
        "\\" + segs.map { s in
            var t = s
            while t.count > 1 && t.hasSuffix("_") { t.removeLast() }
            return t
        }.joined(separator: ".")
    }
}

struct Region { var path: ACPIPath; var space: String; var base: UInt64?; var length: UInt64? }
struct FieldUnit { var path: ACPIPath; var region: ACPIPath; var bitOffset: Int; var bitWidth: Int }
struct MethodInfo { var path: ACPIPath; var args: Int; var body: String; var table: String }

final class Namespace {
    var devices = Set<ACPIPath>()
    var methods: [ACPIPath: MethodInfo] = [:]
    var names = Set<ACPIPath>()
    var mutexes = Set<ACPIPath>()
    var regions: [ACPIPath: Region] = [:]
    var fields: [ACPIPath: FieldUnit] = [:]

    func methods(named n: String) -> [MethodInfo] {
        methods.values.filter { $0.path.last == ACPIPath.pad(n) }.sorted { $0.path.description < $1.path.description }
    }

    func fields(named n: String) -> [FieldUnit] {
        fields.values.filter { $0.path.last == ACPIPath.pad(n) }.sorted { $0.path.description < $1.path.description }
    }

    func field(_ n: String, in dev: ACPIPath) -> FieldUnit? { fields[dev.child(n)] }

    // A region referenced from `scope`: searched upward like ACPI does.
    func findRegion(_ raw: String, from scope: ACPIPath) -> ACPIPath {
        if raw.contains(".") || raw.hasPrefix("\\") || raw.hasPrefix("^") { return ACPIPath.resolve(raw, in: scope) }
        var s = scope
        while true {
            let p = s.child(raw)
            if regions[p] != nil || s.segs.isEmpty { return p }
            s = s.parent
        }
    }

    // MARK: parsing

    private enum Block { case scope(ACPIPath), method(ACPIPath, Int), field(region: String), other }

    private static let scopeRx = try! NSRegularExpression(pattern:
        #"^\s*(Scope|Device|ThermalZone|Processor|PowerResource|Method|Field|IndexField|BankField)\s*\(\s*([\\^A-Za-z0-9_.]+)\s*(?:,\s*([^,)]*))?"#)
    private static let nameRx = try! NSRegularExpression(pattern: #"^\s*Name\s*\(\s*([\\^A-Za-z0-9_.]+)\s*,"#)
    private static let mutexRx = try! NSRegularExpression(pattern: #"^\s*Mutex\s*\(\s*([\\^A-Za-z0-9_.]+)\s*,"#)
    private static let regionRx = try! NSRegularExpression(pattern:
        #"^\s*OperationRegion\s*\(\s*([\\^A-Za-z0-9_.]+)\s*,\s*(\w+)\s*,\s*([^,]+?)\s*,\s*([^)]+?)\s*\)"#)
    private static let fieldEntryRx = try! NSRegularExpression(pattern: #"^\s*([A-Za-z0-9_]{1,4})?\s*,\s*(\d+)\s*,?\s*$"#)
    private static let offsetRx = try! NSRegularExpression(pattern: #"^\s*Offset\s*\(\s*(0x[0-9A-Fa-f]+|\d+)\s*\)"#)

    static func number(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        switch t {
        case "Zero": return 0
        case "One": return 1
        case "Ones": return UInt64.max
        default: break
        }
        if t.lowercased().hasPrefix("0x") { return UInt64(t.dropFirst(2), radix: 16) }
        return UInt64(t)
    }

    private static func groups(_ rx: NSRegularExpression, _ line: String) -> [String?]? {
        let ns = line as NSString
        guard let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
    }

    // Removes comments and string literals, which may contain braces.
    private static func clean(_ text: String) -> [String] {
        var out = "", i = text.startIndex
        var inBlock = false, inLine = false, inString = false
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            let n: Character? = next < text.endIndex ? text[next] : nil
            if inBlock {
                if c == "*" && n == "/" { inBlock = false; i = text.index(after: next); continue }
                if c == "\n" { out.append(c) }
            } else if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if inString {
                if c == "\\" && n != nil { i = text.index(after: next); continue }
                if c == "\"" { inString = false; out.append("\"\"") }
            } else if c == "/" && n == "*" { inBlock = true; i = next
            } else if c == "/" && n == "/" { inLine = true; i = next
            } else if c == "\"" { inString = true
            } else { out.append(c) }
            i = text.index(after: i)
        }
        return out.components(separatedBy: "\n")
    }

    func parse(_ text: String, table: String) {
        var stack: [Block] = []
        var pending: Block?
        var fieldBit = 0
        var methodBodies: [(ACPIPath, Int, [String])] = []

        func scope() -> ACPIPath {
            for b in stack.reversed() {
                switch b {
                case .scope(let p), .method(let p, _): return p
                default: continue
                }
            }
            return .root
        }

        for line in Namespace.clean(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("External") || trimmed.hasPrefix("DefinitionBlock") {
                if trimmed.hasPrefix("DefinitionBlock") { pending = .scope(.root) }
                continue
            }
            for i in methodBodies.indices { methodBodies[i].2.append(trimmed) }

            if case .field(let regionName)? = stack.last, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("}") {
                if let g = Namespace.groups(Namespace.offsetRx, trimmed), let o = Namespace.number(g[0]!) {
                    fieldBit = Int(o) * 8
                } else if let g = Namespace.groups(Namespace.fieldEntryRx, trimmed), let w = Int(g[1]!) {
                    if let n = g[0] {
                        let sc = scope()
                        let p = sc.child(n)
                        fields[p] = FieldUnit(path: p, region: findRegion(regionName, from: sc), bitOffset: fieldBit, bitWidth: w)
                    }
                    fieldBit += w
                }
                continue
            }

            if let g = Namespace.groups(Namespace.scopeRx, trimmed) {
                let kind = g[0]!, raw = g[1]!
                let sc = scope()
                switch kind {
                case "Method":
                    let p = ACPIPath.resolve(raw, in: sc)
                    pending = .method(p, Int(g[2]?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0)
                case "Field", "IndexField", "BankField":
                    pending = .field(region: raw)
                    fieldBit = 0
                default:
                    let p = ACPIPath.resolve(raw, in: sc)
                    if kind != "Scope" { devices.insert(p) }
                    pending = .scope(p)
                }
            } else if let g = Namespace.groups(Namespace.regionRx, trimmed) {
                let p = ACPIPath.resolve(g[0]!, in: scope())
                regions[p] = Region(path: p, space: g[1]!, base: Namespace.number(g[2]!), length: Namespace.number(g[3]!))
            } else if let g = Namespace.groups(Namespace.nameRx, trimmed) {
                names.insert(ACPIPath.resolve(g[0]!, in: scope()))
            } else if let g = Namespace.groups(Namespace.mutexRx, trimmed) {
                mutexes.insert(ACPIPath.resolve(g[0]!, in: scope()))
            }

            for ch in trimmed {
                if ch == "{" {
                    let b = pending ?? .other
                    pending = nil
                    stack.append(b)
                    if case .method(let p, _) = b { methodBodies.append((p, stack.count, [])) }
                } else if ch == "}" {
                    guard let b = stack.popLast() else { continue }
                    if case .method(let p, let args) = b, let idx = methodBodies.lastIndex(where: { $0.0 == p && $0.1 == stack.count + 1 }) {
                        let body = methodBodies.remove(at: idx).2.joined(separator: "\n")
                        methods[p] = MethodInfo(path: p, args: args, body: body, table: table)
                    }
                }
            }
        }
    }
}
