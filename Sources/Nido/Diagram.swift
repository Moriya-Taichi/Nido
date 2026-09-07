import Foundation

public struct GraphNode: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let name: String
    public let type: String
    public let dependencies: [String]
}

public struct InfrastructureGraph: Codable, Equatable, Sendable {
    public let name: String
    public let nodes: [GraphNode]

    public func render(_ format: DiagramFormat) throws -> String {
        // Graph JSON may come from an external file. Validate it before indexing or recursive layout.
        let ids = Set(nodes.map(\.id))
        guard ids.count == nodes.count else { throw NidoError("Graph contains duplicate node IDs") }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var visited = Set<String>(), active = Set<String>()
        func visit(_ id: String) throws {
            guard let node = byID[id] else { throw NidoError("Graph references missing node \(id)") }
            guard !active.contains(id) else { throw NidoError("Graph contains a dependency cycle at \(id)") }
            if visited.contains(id) { return }
            active.insert(id)
            for dep in node.dependencies { try visit(dep) }
            active.remove(id); visited.insert(id)
        }
        for node in nodes { try visit(node.id) }
        switch format {
        case .mermaid: return mermaid()
        case .dot: return dot()
        case .svg: return svg()
        }
    }

    private var sorted: [GraphNode] { nodes.sorted { $0.id < $1.id } }
    private var indexed: [String: Int] { Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1.id, $0) }) }

    private func mermaid() -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "#", with: "#35;")
                .replacingOccurrences(of: "&", with: "#38;")
                .replacingOccurrences(of: "\"", with: "#quot;")
                .replacingOccurrences(of: "<", with: "#60;")
                .replacingOccurrences(of: ">", with: "#62;")
                .replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["flowchart TD"]
        for node in sorted { lines.append("    n\(indexed[node.id]!)[\"\(escape(node.id))\"]") }
        for node in sorted {
            for dep in node.dependencies.sorted() { lines.append("    n\(indexed[dep]!) --> n\(indexed[node.id]!)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func dot() -> String {
        func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        var lines = ["digraph Nido {", "  rankdir=TB;", "  node [shape=box, style=rounded];", "  label=\(quote(name));"]
        for node in sorted { lines.append("  n\(indexed[node.id]!) [label=\(quote(node.id))];") }
        for node in sorted {
            for dep in node.dependencies.sorted() { lines.append("  n\(indexed[dep]!) -> n\(indexed[node.id]!);") }
        }
        return (lines + ["}"]).joined(separator: "\n") + "\n"
    }

    private func svg() -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var ranks: [String: Int] = [:]
        func rank(_ id: String) -> Int {
            if let r = ranks[id] { return r }
            let r = (byID[id]!.dependencies.map(rank).max() ?? -1) + 1
            ranks[id] = r
            return r
        }
        for node in sorted { _ = rank(node.id) }
        var positions: [String: (Int, Int)] = [:]
        var row = 0
        let largestLevel = Dictionary(grouping: nodes, by: { ranks[$0.id]! }).values.map(\.count).max() ?? 1
        let columns = min(4, max(1, largestLevel))
        let width = columns * 300 + 40
        for level in Set(ranks.values).sorted() {
            let items = sorted.filter { ranks[$0.id] == level }
            for (index, node) in items.enumerated() {
                let rowCount = min(columns, items.count - (index / columns) * columns)
                let inset = (columns - rowCount) * 150
                positions[node.id] = (40 + inset + (index % columns) * 300, 88 + (row + index / columns) * 144)
            }
            row += (items.count + columns - 1) / columns
        }
        let height = max(200, row * 144 + 80)
        var lines = [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\" role=\"img\" aria-labelledby=\"title desc\">",
            "<title id=\"title\">\(escape(name))</title>",
            "<desc id=\"desc\">Infrastructure dependencies. Arrows point from a dependency to its consumer. Configuration values are omitted.</desc>",
            "<defs><marker id=\"arrow\" markerWidth=\"8\" markerHeight=\"8\" refX=\"7\" refY=\"3\" orient=\"auto\"><path d=\"M0,0 L0,6 L8,3 z\" fill=\"#64748b\"/></marker></defs>",
            "<rect width=\"100%\" height=\"100%\" fill=\"#f8fafc\"/>",
            "<text x=\"40\" y=\"42\" font-family=\"system-ui,sans-serif\" font-size=\"24\" fill=\"#0f172a\">\(escape(name))</text>",
        ]
        for node in sorted {
            let (tx, ty) = positions[node.id]!
            for dep in node.dependencies.sorted() {
                let (sx, sy) = positions[dep]!
                let mid = (sy + 76 + ty) / 2
                let path: String
                if ty - sy > 144 {
                    // Route edges that skip rows around nodes instead of through their boxes.
                    let lane = width - 14
                    path = "M\(sx + 130),\(sy + 76) V\(sy + 96) H\(lane) V\(ty - 20) H\(tx + 130) V\(ty - 3)"
                } else {
                    path = "M\(sx + 130),\(sy + 76) C\(sx + 130),\(mid) \(tx + 130),\(mid) \(tx + 130),\(ty - 3)"
                }
                lines.append("<path d=\"\(path)\" fill=\"none\" stroke=\"#64748b\" stroke-width=\"1.5\" marker-end=\"url(#arrow)\"/>")
            }
        }
        for node in sorted {
            let (x, y) = positions[node.id]!
            let label = String(node.name.prefix(29)) + (node.name.count > 29 ? "…" : "")
            let kind = node.type.isEmpty ? node.kind : node.type
            let detail = String(kind.prefix(32)) + (kind.count > 32 ? "…" : "")
            lines += [
                "<g><title>\(escape(node.id))</title><rect x=\"\(x)\" y=\"\(y)\" width=\"260\" height=\"76\" rx=\"10\" fill=\"white\" stroke=\"#cbd5e1\"/>",
                "<rect x=\"\(x)\" y=\"\(y + 14)\" width=\"4\" height=\"48\" rx=\"2\" fill=\"#f06445\"/>",
                "<text x=\"\(x + 16)\" y=\"\(y + 31)\" font-family=\"system-ui,sans-serif\" font-size=\"15\" fill=\"#0f172a\">\(escape(label))</text>",
                "<text x=\"\(x + 16)\" y=\"\(y + 54)\" font-family=\"system-ui,sans-serif\" font-size=\"12\" fill=\"#475569\">\(escape(detail))</text></g>",
            ]
        }
        return (lines + ["</svg>"]).joined(separator: "\n") + "\n"
    }
}

public enum DiagramFormat: String, Sendable { case mermaid, dot, svg }
