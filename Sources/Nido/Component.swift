import Foundation

public struct NidoError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Dependency: Hashable, Sendable {
    public let address: String
    public init(_ address: String) { self.address = address }
}

public enum BlockKind: String, Codable, Sendable {
    case resource, data, provider, variable, output, local, module
}

public struct Block: Sendable {
    public let kind: BlockKind
    public let type: String
    public let name: String
    public var attributes: [String: AnyValue]
    public var literalAttributes: [String: JSONValue]
    public var dependencies: Set<String>
    public var issues: [String]
    public var providerRequirement: ProviderRequirement?

    public init(kind: BlockKind, type: String = "", name: String,
                attributes: [String: AnyValue] = [:], literalAttributes: [String: JSONValue] = [:],
                dependencies: Set<String> = [], issues: [String] = [],
                providerRequirement: ProviderRequirement? = nil) {
        self.kind = kind; self.type = type; self.name = name
        self.attributes = attributes; self.literalAttributes = literalAttributes
        self.dependencies = dependencies; self.issues = issues
        self.providerRequirement = providerRequirement
    }

    public var address: String {
        switch kind {
        case .resource: "\(type).\(name)"
        case .data: "data.\(type).\(name)"
        case .provider: "provider.\(type).\(name)"
        case .variable: "var.\(name)"
        default: "\(kind.rawValue).\(name)"
        }
    }

    var allDependencies: Set<String> {
        attributes.values.reduce(into: dependencies) { $0.formUnion($1.expression.dependencies) }
    }

    var json: JSONValue {
        var values = attributes.mapValues { $0.expression.json }
        values.merge(literalAttributes) { _, new in new }
        return .object(values)
    }
}

public protocol Component: Sendable { var blocks: [Block] { get } }
public struct Components: Component {
    public let blocks: [Block]
    public init(@StackBuilder _ content: () -> [Block]) { blocks = content() }
}

@resultBuilder public enum StackBuilder {
    public static func buildExpression<C: Component>(_ c: C) -> [Block] { c.blocks }
    public static func buildBlock(_ parts: [Block]...) -> [Block] { parts.flatMap { $0 } }
    public static func buildOptional(_ c: [Block]?) -> [Block] { c ?? [] }
    public static func buildEither(first c: [Block]) -> [Block] { c }
    public static func buildEither(second c: [Block]) -> [Block] { c }
    public static func buildArray(_ c: [[Block]]) -> [Block] { c.flatMap { $0 } }
    public static func buildLimitedAvailability(_ c: [Block]) -> [Block] { c }
}

public struct ProviderRequirement: Equatable, Sendable {
    public let name: String
    public let source: String
    public let version: String
    public init(_ name: String, source: String, version: String) {
        self.name = name; self.source = source; self.version = version
    }
}

public struct Provider: Component {
    public let requirement: ProviderRequirement
    public let alias: String?
    public let configuration: [String: AnyValue]
    public let issues: [String]
    public init(_ requirement: ProviderRequirement, alias: String? = nil,
                configuration: [String: AnyValue] = [:], issues: [String] = []) {
        self.requirement = requirement; self.alias = alias; self.configuration = configuration
        self.issues = issues
    }
    public var reference: String { requirement.name + (alias.map { ".\($0)" } ?? "") }
    public var dependency: Dependency { Dependency("provider.\(requirement.name).\(alias ?? "default")") }
    public var blocks: [Block] {
        [Block(kind: .provider, type: requirement.name, name: alias ?? "default",
               attributes: configuration, literalAttributes: alias.map { ["alias": .string($0)] } ?? [:],
               issues: issues, providerRequirement: requirement)]
    }
}

public enum IgnoreChanges: Sendable {
    case all
    case attributes([String])
}

public struct Lifecycle: Sendable {
    public var createBeforeDestroy: Bool
    public var preventDestroy: Bool
    public var ignoreChanges: IgnoreChanges?
    public init(createBeforeDestroy: Bool = false, preventDestroy: Bool = false,
                ignoreChanges: IgnoreChanges? = nil) {
        self.createBeforeDestroy = createBeforeDestroy; self.preventDestroy = preventDestroy
        self.ignoreChanges = ignoreChanges
    }
    var json: JSONValue {
        var result: [String: JSONValue] = ["create_before_destroy": .bool(createBeforeDestroy),
                                           "prevent_destroy": .bool(preventDestroy)]
        if let ignoreChanges {
            switch ignoreChanges {
            case .all: result["ignore_changes"] = .string("all")
            case .attributes(let names): result["ignore_changes"] = .array(names.map(JSONValue.string))
            }
        }
        return .object(result)
    }
}

public struct ResourceOptions: Sendable {
    public var dependsOn: [Dependency]
    public var lifecycle: Lifecycle?
    public init(dependsOn: [Dependency] = [], lifecycle: Lifecycle? = nil) {
        self.dependsOn = dependsOn; self.lifecycle = lifecycle
    }
}

public struct DataSourceOptions: Sendable {
    public var dependsOn: [Dependency]
    public init(dependsOn: [Dependency] = []) { self.dependsOn = dependsOn }
}

public protocol ResourceKind: Sendable {
    static var terraformType: String { get }
    static var blockKind: BlockKind { get }
}
extension ResourceKind { public static var blockKind: BlockKind { .resource } }

/// Provider implementers use this lower-level API. End users should prefer typed wrappers.
public struct Resource<Kind: ResourceKind>: Component {
    public let block: Block
    public init(_ name: String, attributes: [String: AnyValue], provider: Provider? = nil,
                options: ResourceOptions = .init(), issues: [String] = []) {
        var literals: [String: JSONValue] = [:]
        var deps = Set(options.dependsOn.map(\.address))
        if let provider {
            literals["provider"] = .string(provider.reference)
            deps.insert(provider.dependency.address)
        }
        if !options.dependsOn.isEmpty {
            literals["depends_on"] = .array(options.dependsOn.map { .string($0.address) })
        }
        if let lifecycle = options.lifecycle { literals["lifecycle"] = lifecycle.json }
        block = Block(kind: Kind.blockKind, type: Kind.terraformType, name: name,
                      attributes: attributes, literalAttributes: literals, dependencies: deps, issues: issues)
    }
    init(block: Block) { self.block = block }
    public var blocks: [Block] { [block] }
    public var dependency: Dependency { Dependency(block.address) }

    /// Schema authors must supply the actual attribute type; application code should use typed properties.
    public func unsafeAttribute<T>(_ name: String, as: T.Type = T.self, sensitive: Bool = false) -> Value<T> {
        Value(.reference("\(block.address).\(name)", [block.address]), sensitive: sensitive)
    }

    public func counted(_ count: Value<Int>) -> CountedResource<Kind> {
        var block = block
        block.attributes["count"] = count.erased
        return CountedResource(block: block)
    }

    public func forEach(_ values: Value<[String: String]>) -> KeyedResource<Kind> {
        var block = block
        block.attributes["for_each"] = values.erased
        return KeyedResource(block: block)
    }
}

public struct CountedResource<Kind: ResourceKind>: Component {
    let block: Block
    public var blocks: [Block] { [block] }
    public func unsafeAttribute<T>(_ name: String, at index: Int, as: T.Type = T.self) -> Value<T> {
        Value(.reference("\(block.address)[\(index)].\(name)", [block.address]))
    }
}
public struct KeyedResource<Kind: ResourceKind>: Component {
    let block: Block
    public var blocks: [Block] { [block] }
    public func unsafeAttribute<T>(_ name: String, at key: String, as: T.Type = T.self) -> Value<T> {
        // JSON string encoding is also valid HCL quoted-string syntax after escaping templates.
        let escaped = key.replacingOccurrences(of: "${", with: "$${").replacingOccurrences(of: "%{", with: "%%{")
        let quoted = String(data: try! JSONEncoder().encode(escaped), encoding: .utf8)!
        return Value(.reference("\(block.address)[\(quoted)].\(name)", [block.address]))
    }
}

public struct Variable<T: TerraformLiteral>: Component {
    public let name: String
    let defaultValue: T?
    let description: String
    let isSensitive: Bool
    public init(_ name: String, default defaultValue: T? = nil, description: String = "", sensitive: Bool = false) {
        self.name = name; self.defaultValue = defaultValue; self.description = description
        isSensitive = sensitive
    }
    public var value: Value<T> { Value(.reference("var.\(name)", ["var.\(name)"]), sensitive: isSensitive) }
    public var blocks: [Block] {
        var attrs: [String: JSONValue] = ["type": .string(T.terraformType), "description": .string(description),
                                         "sensitive": .bool(isSensitive), "nullable": .bool(false)]
        if let defaultValue { attrs["default"] = defaultValue.terraformLiteral }
        return [Block(kind: .variable, name: name, literalAttributes: attrs)]
    }
}

public struct Output<T>: Component {
    let name: String
    let value: Value<T>
    let description: String
    let isSensitive: Bool
    public init(_ name: String, value: Value<T>, description: String = "", sensitive: Bool = false) {
        self.name = name; self.value = value; self.description = description
        isSensitive = sensitive || value.isSensitive
    }
    public var blocks: [Block] {
        [Block(kind: .output, name: name, attributes: ["value": value.erased],
               literalAttributes: ["description": .string(description), "sensitive": .bool(isSensitive)])]
    }
}

public struct Local<T>: Component {
    let name: String
    let input: Value<T>
    public init(_ name: String, value: Value<T>) { self.name = name; input = value }
    public var value: Value<T> { Value(.reference("local.\(name)", ["local.\(name)"]), sensitive: input.isSensitive) }
    public var blocks: [Block] { [Block(kind: .local, name: name, attributes: ["value": input.erased])] }
}

public enum TerraformDataKind: ResourceKind { public static let terraformType = "terraform_data" }
public struct TerraformData<T>: Component {
    public let resource: Resource<TerraformDataKind>
    public init(_ name: String, input: Value<T>, triggersReplace: AnyValue? = nil,
                options: ResourceOptions = .init()) {
        var attrs = ["input": input.erased]
        if let triggersReplace { attrs["triggers_replace"] = triggersReplace }
        resource = Resource(name, attributes: attrs, options: options)
    }
    public var id: Value<String> { resource.unsafeAttribute("id") }
    public var output: Value<T> {
        resource.unsafeAttribute("output", sensitive: resource.block.attributes["input"]?.isSensitive ?? false)
    }
    public var dependency: Dependency { resource.dependency }
    public var blocks: [Block] { resource.blocks }
}

/// Reuse any Terraform module. Wrap unsafeOutput in a Swift type to describe its output contract.
public struct TerraformModule: Component {
    public let block: Block
    public init(_ name: String, source: String, version: String? = nil,
                inputs: [String: AnyValue] = [:], providers: [String: Provider] = [:],
                dependsOn: [Dependency] = []) {
        var attrs: [String: JSONValue] = ["source": .string(source)]
        if let version { attrs["version"] = .string(version) }
        if !providers.isEmpty { attrs["providers"] = .object(providers.mapValues { .string($0.reference) }) }
        if !dependsOn.isEmpty { attrs["depends_on"] = .array(dependsOn.map { .string($0.address) }) }
        block = Block(kind: .module, name: name, attributes: inputs, literalAttributes: attrs,
                      dependencies: Set(dependsOn.map(\.address) + providers.values.map { $0.dependency.address }))
    }
    public var blocks: [Block] { [block] }
    public var dependency: Dependency { Dependency(block.address) }
    public func unsafeOutput<T>(_ name: String, as: T.Type = T.self, sensitive: Bool = false) -> Value<T> {
        Value(.reference("\(block.address).\(name)", [block.address]), sensitive: sensitive)
    }
}
