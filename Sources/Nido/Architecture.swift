import Foundation

/// Diagram metadata only: it never changes Terraform configuration.
public struct Architecture: Codable, Equatable, Sendable {
    public let groups: [DiagramGroup]
    public let services: [DiagramService]
    public let connections: [DiagramConnection]
    public init(groups: [DiagramGroup] = [], services: [DiagramService], connections: [DiagramConnection] = []) {
        self.groups = groups; self.services = services; self.connections = connections
    }

    func validate(resourceIDs: Set<String>) throws {
        let all = groups.map(\.id) + services.map(\.id)
        guard Set(all).count == all.count else { throw NidoError("Duplicate architecture ID") }
        let groupIDs = Set(groups.map(\.id)), serviceIDs = Set(services.map(\.id))
        let parents = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.parent) })
        for group in groups {
            var seen: Set<String> = [group.id], parent = group.parent
            while let id = parent {
                guard groupIDs.contains(id), seen.insert(id).inserted else {
                    throw NidoError("Missing or cyclic architecture group: \(id)")
                }
                parent = parents[id] ?? nil
            }
        }
        for service in services {
            if let parent = service.parent, !groupIDs.contains(parent) { throw NidoError("Missing architecture group: \(parent)") }
            if let resource = service.resource, !resourceIDs.contains(resource) { throw NidoError("Missing architecture resource: \(resource)") }
        }
        for link in connections {
            guard serviceIDs.contains(link.from), serviceIDs.contains(link.to) else { throw NidoError("Missing architecture connection endpoint") }
        }
    }

    static func inferred(_ nodes: [GraphNode]) -> Architecture {
        let resources = nodes.filter { $0.kind == "resource" || $0.kind == "module" }
        let aws = resources.contains { $0.type.hasPrefix("aws_") }
        return Architecture(groups: aws ? [.init("aws", label: "AWS Cloud", kind: .cloud)] : [], services: resources.map {
            .init($0.id, label: $0.name, icon: ServiceIcon.infer($0.type),
                  parent: $0.type.hasPrefix("aws_") ? "aws" : nil, resource: $0.id, detail: $0.type)
        })
    }
}

public enum DiagramGroupKind: String, Codable, Sendable { case cloud, region, vpc, availabilityZone, subnet, generic }
public struct DiagramGroup: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: DiagramGroupKind
    public let parent: String?
    /// Siblings with the same row are laid out horizontally. Rows run from top to bottom.
    public let row: Int
    public init(_ id: String, label: String, kind: DiagramGroupKind = .generic, parent: String? = nil, row: Int = 0) {
        self.id = id; self.label = label; self.kind = kind; self.parent = parent; self.row = row
    }
}
public enum ServiceIcon: String, Codable, Sendable {
    case client, mobile, internet, compute, container, function, database, bucket, loadBalancer, cdn, gateway, security, identity, workflow, generic
    static func infer(_ type: String) -> Self {
        if type.contains("s3_bucket") { return .bucket }
        if type.contains("lambda") { return .function }
        if type.contains("cloudfront") { return .cdn }
        if type.contains("dynamodb") || type.contains("db_instance") || type.contains("rds") { return .database }
        if type.contains("ecs") || type.contains("eks") { return .container }
        if type.contains("security") || type.contains("waf") { return .security }
        if type.contains("cognito") { return .identity }
        if type.contains("api_gateway") { return .gateway }
        if type == "aws_lb" || type.contains("elb") { return .loadBalancer }
        if type == "aws_instance" { return .compute }
        return .generic
    }
}
public struct DiagramService: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let icon: ServiceIcon
    public let parent: String?
    public let resource: String?
    public let detail: String
    public let row: Int
    /// Omit resource for external actors or conceptual services. Resource addresses are checked against the stack.
    public init(_ id: String, label: String, icon: ServiceIcon = .generic, parent: String? = nil,
                resource: String? = nil, detail: String = "", row: Int = 0) {
        self.id = id; self.label = label; self.icon = icon; self.parent = parent
        self.resource = resource; self.detail = detail; self.row = row
    }
}
public struct DiagramConnection: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case traffic, replication }
    public let from: String
    public let to: String
    public let label: String
    public let kind: Kind
    public init(_ from: String, _ to: String, label: String = "", kind: Kind = .traffic) {
        self.from = from; self.to = to; self.label = label; self.kind = kind
    }
}

extension Architecture {
    private func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    func render(_ format: DiagramFormat, name: String) -> String {
        if format == .svg { return svg(name: name) }
        let ids = Dictionary(uniqueKeysWithValues: (groups.map(\.id) + services.map(\.id)).sorted().enumerated().map { ($1, "n\($0)") })
        func quote(_ s: String) -> String {
            if format == .mermaid {
                return "\"" + s.replacingOccurrences(of: "#", with: "#35;").replacingOccurrences(of: "&", with: "#38;").replacingOccurrences(of: "\"", with: "#quot;").replacingOccurrences(of: "<", with: "#60;").replacingOccurrences(of: ">", with: "#62;").replacingOccurrences(of: "\n", with: " ") + "\""
            }
            return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        var lines = format == .mermaid ? ["flowchart TB"] : ["digraph Nido {", "compound=true; rankdir=TB; node [shape=box];"]
        func emit(_ parent: String?) {
            for group in groups.filter({ $0.parent == parent }).sorted(by: { $0.id < $1.id }) {
                lines.append(format == .mermaid ? "subgraph \(ids[group.id]!) [\(quote(group.label))]" : "subgraph cluster_\(ids[group.id]!) { label=\(quote(group.label));")
                emit(group.id)
                lines.append(format == .mermaid ? "end" : "}")
            }
            for service in services.filter({ $0.parent == parent }).sorted(by: { $0.id < $1.id }) {
                lines.append(format == .mermaid ? "\(ids[service.id]!)[\(quote(service.label))]" : "\(ids[service.id]!) [label=\(quote(service.label))];")
            }
        }
        emit(nil)
        for link in connections {
            let a = ids[link.from]!, b = ids[link.to]!
            if format == .mermaid {
                let label = link.label.isEmpty ? "" : "|\(quote(link.label))|"
                lines.append("\(a) \(link.kind == .replication ? "<-->" : "-->")\(label) \(b)")
            } else {
                lines.append("\(a) -> \(b) [label=\(quote(link.label)), dir=\(link.kind == .replication ? "both" : "forward")];")
            }
        }
        if format == .dot { lines.append("}") }
        return lines.joined(separator: "\n") + "\n"
    }

    private struct Box { var x: Int; var y: Int; var w: Int; var h: Int }
    private func svg(name: String) -> String {
        var boxes: [String: Box] = [:]
        // Bottom-up sizing keeps every nested boundary clear of its children.
        func layout(_ parent: String?, x: Int, y: Int) -> (Int, Int) {
            let children = groups.filter { $0.parent == parent }.map { ($0.id, $0.row, true) }
                + services.filter { $0.parent == parent }.map { ($0.id, $0.row, false) }
            var yy = y + 56, width = 240
            for row in Set(children.map { $0.1 }).sorted() {
                var xx = x + 32, height = 0
                for (id, _, group) in children.filter({ $0.1 == row }).sorted(by: { $0.0 < $1.0 }) {
                    let size = group ? layout(id, x: xx, y: yy) : (196, 152)
                    boxes[id] = Box(x: xx, y: yy, w: size.0, h: size.1)
                    xx += size.0 + 48; height = max(height, size.1)
                }
                width = max(width, xx - x - 16); yy += height + 64
            }
            func shift(_ id: String, by dx: Int) {
                boxes[id]!.x += dx
                for child in groups where child.parent == id { shift(child.id, by: dx) }
                for child in services where child.parent == id { boxes[child.id]!.x += dx }
            }
            for row in Set(children.map { $0.1 }).sorted() {
                let members = children.filter { $0.1 == row }
                let used = members.reduce(0) { $0 + boxes[$1.0]!.w } + max(0, members.count - 1) * 48
                let inset = max(0, (width - 64 - used) / 2)
                for child in members { shift(child.0, by: inset) }
            }
            return (width, max(160, yy - y - 32))
        }
        let size = layout(nil, x: 0, y: 72)
        var lines = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(size.0)\" height=\"\(size.1 + 112)\" viewBox=\"0 0 \(size.0) \(size.1 + 112)\" role=\"img\" aria-labelledby=\"title desc\">",
            "<title id=\"title\">\(xml(name))</title><desc id=\"desc\">Architecture. Solid arrows show declared traffic; dashed double arrows show replication. Symbols are Nido icons, not official provider artwork.</desc>",
            "<defs><marker id=\"arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0 0L10 5L0 10Z\" fill=\"#526477\"/></marker></defs>",
            "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>",
            "<g font-family=\"system-ui,sans-serif\" fill=\"#243247\"><text x=\"32\" y=\"40\" font-size=\"24\">\(xml(name))</text><text x=\"32\" y=\"65\" font-size=\"12\">Architecture · → Traffic · ↔ Replication (dashed)</text>"]
        func drawGroups(_ parent: String?) {
            for group in groups.filter({ $0.parent == parent }).sorted(by: { $0.id < $1.id }) {
                let b = boxes[group.id]!
                let dashed = group.kind == .availabilityZone || group.kind == .subnet
                lines.append("<rect x=\"\(b.x)\" y=\"\(b.y)\" width=\"\(b.w)\" height=\"\(b.h)\" rx=\"8\" fill=\"\(group.kind == .cloud ? "#ffffff" : "#f8fafc")\" stroke=\"#8799ad\"\(dashed ? " stroke-dasharray=\"8 5\"" : "")/><text x=\"\(b.x + 16)\" y=\"\(b.y + 28)\" font-size=\"15\">\(xml(group.label))</text>")
                drawGroups(group.id)
            }
        }
        drawGroups(nil)
        for (index, link) in connections.enumerated() {
            let a = boxes[link.from]!, b = boxes[link.to]!
            let sx: Int, sy: Int, tx: Int, ty: Int, path: String, lx: Int, ly: Int
            if link.from == link.to {
                sx = a.x + a.w; sy = a.y + 30; tx = sx; ty = a.y + 76
                path = "M\(sx) \(sy)H\(sx + 20)V\(ty)H\(tx)"; lx = sx + 20; ly = sy - 10
            } else if a.y + a.h <= b.y || b.y + b.h <= a.y {
                let down = b.y > a.y
                sx = a.x + a.w / 2; tx = b.x + b.w / 2
                sy = down ? a.y + a.h : a.y; ty = down ? b.y : b.y + b.h
                let mid = (sy + ty) / 2 + (index % 3) * 6
                path = "M\(sx) \(sy)V\(mid)H\(tx)V\(ty)"; lx = (sx + tx) / 2; ly = mid - 8
            } else {
                let right = b.x > a.x
                sx = right ? a.x + a.w : a.x; tx = right ? b.x : b.x + b.w
                sy = a.y + 50; ty = b.y + 50
                let mid = (sx + tx) / 2
                path = "M\(sx) \(sy)H\(mid)V\(ty)H\(tx)"; lx = mid; ly = min(sy, ty) - 10
            }
            lines.append("<path d=\"\(path)\" fill=\"none\" stroke=\"#526477\" stroke-width=\"1.5\" marker-end=\"url(#arrow)\"\(link.kind == .replication ? " marker-start=\"url(#arrow)\" stroke-dasharray=\"6 4\"" : "")/>")
            if !link.label.isEmpty {
                let label = String(link.label.prefix(48)), width = label.count * 7 + 12
                lines.append("<rect x=\"\(lx - width / 2)\" y=\"\(ly - 12)\" width=\"\(width)\" height=\"17\" rx=\"3\" fill=\"white\"/><text x=\"\(lx)\" y=\"\(ly)\" text-anchor=\"middle\" font-size=\"11\">\(xml(label))</text>")
            }
        }
        for service in services.sorted(by: { $0.id < $1.id }) {
            let b = boxes[service.id]!, cx = b.x + b.w / 2
            lines.append("<g><title>\(xml(service.resource ?? service.id))</title><g transform=\"translate(\(cx - 36) \(b.y + 10))\">\(symbol(service.icon))</g>")
            for (offset, value) in [service.label, service.detail].enumerated() {
                // Long labels wrap rather than expand into neighboring services.
                let chars = Array(value), count = max(1, (chars.count + 23) / 24)
                for line in 0..<min(2, count) {
                    let start = line * 24, end = min(chars.count, start + 24)
                    let label = String(chars[start..<end]) + (line == 1 && count > 2 ? "…" : "")
                    lines.append("<text x=\"\(cx)\" y=\"\(b.y + 104 + offset * 30 + line * 14)\" text-anchor=\"middle\" font-size=\"\(offset == 0 ? 14 : 11)\">\(xml(label))</text>")
                }
            }
            lines.append("</g>")
        }
        return (lines + ["</g></svg>"]).joined(separator: "\n") + "\n"
    }

    /// Original geometric symbols. No downloads, external fonts, or proprietary icon bundle required.
    private func symbol(_ icon: ServiceIcon) -> String {
        let color: String
        switch icon {
        case .compute, .container, .function: color = "#ed7d13"
        case .database: color = "#a529c6"
        case .bucket: color = "#719d19"
        case .security, .identity: color = "#dc3456"
        case .client, .mobile, .internet, .generic: color = "#526477"
        default: color = "#8050d6"
        }
        let path: String
        switch icon {
        case .database: path = "<ellipse cx='36' cy='20' rx='21' ry='8'/><path d='M15 20v32c0 11 42 11 42 0V20M15 36c0 11 42 11 42 0'/>"
        case .bucket: path = "<ellipse cx='36' cy='18' rx='23' ry='7'/><path d='M13 18l6 38q17 10 34 0l6-38M25 33q11 15 22 0'/>"
        case .client: path = "<rect x='12' y='14' width='48' height='34' rx='2'/><path d='M36 48v10M22 60h28'/>"
        case .mobile: path = "<rect x='22' y='9' width='28' height='54' rx='4'/><path d='M30 16h12M32 55h8'/>"
        case .function: path = "<path d='M20 14h13l20 44h9M30 29L15 58h14l9-18'/>"
        case .security: path = "<path d='M36 10L58 19v17q0 16-22 27Q14 52 14 36V19ZM25 35l8 8 15-18'/>"
        case .loadBalancer, .workflow: path = "<circle cx='17' cy='36' r='7'/><rect x='48' y='10' width='14' height='14'/><rect x='48' y='48' width='14' height='14'/><path d='M24 36h12V17h12M36 36v19h12'/>"
        case .cdn, .internet: path = "<circle cx='36' cy='36' r='25'/><ellipse cx='36' cy='36' rx='12' ry='25'/><path d='M12 29h48M12 43h48'/>"
        case .gateway: path = "<path d='M12 14v44h12V14ZM48 14v44h12V14ZM27 27l-6 9 6 9M45 27l6 9-6 9M40 23l-8 26'/>"
        case .identity: path = "<rect x='10' y='17' width='52' height='38' rx='3'/><circle cx='27' cy='31' r='7'/><path d='M17 48q10-17 20 0M44 28h10M44 37h10'/>"
        case .container: path = "<path d='M36 10L59 23v27L36 63 13 50V23ZM13 23l23 14 23-14M36 37v26'/>"
        default: path = "<rect x='19' y='19' width='34' height='34' rx='3'/><path d='M27 10v9M45 10v9M27 53v9M45 53v9M10 27h9M10 45h9M53 27h9M53 45h9'/>"
        }
        return "<rect width='72' height='72' rx='4' fill='\(color)'/><g fill='none' stroke='white' stroke-width='2.3' stroke-linecap='round' stroke-linejoin='round'>\(path)</g>"
    }
}
