import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct Backend: Sendable {
    public let kind: String
    public let configuration: [String: JSONValue]
    public init(_ kind: String, configuration: [String: JSONValue] = [:]) {
        self.kind = kind; self.configuration = configuration
    }
}

public struct Import: Sendable {
    public let id: Value<String>
    public let to: Dependency
    public init(id: Value<String>, to: Dependency) { self.id = id; self.to = to }
}
public struct Move: Sendable {
    public let from: String
    public let to: Dependency
    public init(from: String, to: Dependency) { self.from = from; self.to = to }
}

public struct Stack: Component {
    public let name: String
    public let blocks: [Block]
    public let backend: Backend?
    public let requiredVersion: String
    public let imports: [Import]
    public let moves: [Move]

    public init(_ name: String, backend: Backend? = nil, requiredVersion: String = ">= 1.5.0",
                imports: [Import] = [], moves: [Move] = [], @StackBuilder content: () -> [Block]) {
        self.name = name; self.backend = backend; self.requiredVersion = requiredVersion
        self.imports = imports; self.moves = moves; blocks = content()
    }

    public func validate() throws {
        var byAddress: [String: Block] = [:]
        for block in blocks {
            guard Self.isIdentifier(block.name), block.type.isEmpty || Self.isIdentifier(block.type) else {
                throw NidoError("Invalid Terraform identifier: \(block.address)")
            }
            guard byAddress.updateValue(block, forKey: block.address) == nil else {
                throw NidoError("Duplicate declaration: \(block.address)")
            }
            let issues = block.issues + block.attributes.keys.sorted().flatMap { block.attributes[$0]!.expression.issues }
            if !issues.isEmpty { throw NidoError("\(block.address): \(issues.joined(separator: "; "))") }
            let overlaps = Set(block.attributes.keys).intersection(block.literalAttributes.keys)
            guard overlaps.isEmpty else { throw NidoError("Conflicting attributes on \(block.address): \(overlaps.sorted())") }
            if block.attributes["count"] != nil && block.attributes["for_each"] != nil {
                throw NidoError("\(block.address) cannot use both count and for_each")
            }
        }
        for block in blocks {
            for dep in block.allDependencies.sorted() where byAddress[dep] == nil {
                throw NidoError("\(block.address) references \(dep), which is missing from this stack")
            }
        }
        var visited = Set<String>()
        var path: [String] = []
        func visit(_ address: String) throws {
            if let start = path.firstIndex(of: address) {
                throw NidoError("Dependency cycle: \((Array(path[start...]) + [address]).joined(separator: " -> "))")
            }
            if visited.contains(address) { return }
            path.append(address)
            for dep in byAddress[address]!.allDependencies.sorted() { try visit(dep) }
            path.removeLast()
            visited.insert(address)
        }
        for address in byAddress.keys.sorted() { try visit(address) }
        var imported = Set<String>()
        for item in imports {
            guard byAddress[item.to.address]?.kind == .resource else {
                throw NidoError("Import target must be a declared managed resource: \(item.to.address)")
            }
            guard imported.insert(item.to.address).inserted else { throw NidoError("Duplicate import: \(item.to.address)") }
            for dep in item.id.expression.dependencies where byAddress[dep] == nil {
                throw NidoError("Import references undeclared \(dep)")
            }
        }
        var movedFrom = Set<String>(), movedTo = Set<String>()
        for move in moves {
            guard byAddress[move.to.address] != nil, move.from != move.to.address else {
                throw NidoError("Invalid move target: \(move.to.address)")
            }
            guard movedFrom.insert(move.from).inserted, movedTo.insert(move.to.address).inserted else {
                throw NidoError("Duplicate move: \(move.from) -> \(move.to.address)")
            }
        }
        _ = try providerRequirements()
    }

    static func isIdentifier(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil
    }

    private func providerRequirements() throws -> [String: JSONValue] {
        var requirements: [String: ProviderRequirement] = [:]
        for block in blocks {
            guard let requirement = block.providerRequirement else { continue }
            if let existing = requirements[requirement.name], existing != requirement {
                throw NidoError("Conflicting source/version requirements for provider \(requirement.name)")
            }
            requirements[requirement.name] = requirement
        }
        return requirements.mapValues { .object(["source": .string($0.source), "version": .string($0.version)]) }
    }

    public func configuration() throws -> JSONValue {
        try validate()
        var terraform: [String: JSONValue] = ["required_version": .string(requiredVersion)]
        let requirements = try providerRequirements()
        if !requirements.isEmpty { terraform["required_providers"] = .object(requirements) }
        if let backend { terraform["backend"] = .object([backend.kind: .object(backend.configuration)]) }
        var root: [String: JSONValue] = ["terraform": .object(terraform), "//": .string("Generated by Nido. Edit the Swift source.")]
        var labeled: [String: [String: [String: JSONValue]]] = [:]
        var single: [String: [String: JSONValue]] = [:]
        var providers: [String: [JSONValue]] = [:]
        for block in blocks.sorted(by: { $0.address < $1.address }) {
            switch block.kind {
            case .resource, .data:
                labeled[block.kind.rawValue, default: [:]][block.type, default: [:]][block.name] = block.json
            case .provider: providers[block.type, default: []].append(block.json)
            case .local: single["locals", default: [:]][block.name] = block.attributes["value"]?.expression.json
            default: single[block.kind.rawValue, default: [:]][block.name] = block.json
            }
        }
        for (kind, types) in labeled { root[kind] = .object(types.mapValues(JSONValue.object)) }
        for (kind, values) in single { root[kind] = .object(values) }
        if !providers.isEmpty { root["provider"] = .object(providers.mapValues(JSONValue.array)) }
        if !imports.isEmpty {
            root["import"] = .array(imports.map { .object(["id": $0.id.expression.json, "to": .string($0.to.address)]) })
        }
        if !moves.isEmpty {
            root["moved"] = .array(moves.map { .object(["from": .string($0.from), "to": .string($0.to.address)]) })
        }
        return .object(root)
    }

    public func graph() throws -> InfrastructureGraph {
        try validate()
        return InfrastructureGraph(name: name, nodes: blocks.map { block in
            GraphNode(id: block.address, kind: block.kind.rawValue, name: block.name,
                      type: block.type, dependencies: block.allDependencies.sorted())
        }.sorted { $0.id < $1.id })
    }

    /// Writes only Nido-owned files; never deletes state, provider locks, or other configuration files.
    public func synthesize(to directory: URL) throws {
        let config = try configuration().encoded()
        let graph = try graph()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicFile.write(config, to: directory.appendingPathComponent("main.tf.json"))
        try AtomicFile.write(encoder.encode(graph), to: directory.appendingPathComponent("nido.graph.json"))
    }

    /// Entry point for an infrastructure executable invoked by `nido` or directly with SwiftPM.
    public func export(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws {
        guard arguments.count == 2, arguments[0] == "--nido-output" else {
            throw NidoError("Run with: --nido-output <directory>, or use the nido CLI")
        }
        try synthesize(to: URL(fileURLWithPath: arguments[1], isDirectory: true))
    }
}

public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".nido-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw NidoError("Cannot create temporary file in \(url.deletingLastPathComponent().path)")
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp)
        guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
