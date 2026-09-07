import Foundation
import Nido

private struct Document: Decodable {
    let format_version: String
    let provider_schemas: [String: ProviderSchema]
}
private struct ProviderSchema: Decodable {
    let provider: Schema?
    let resource_schemas: [String: Schema]?
    let data_source_schemas: [String: Schema]?
}
private struct Schema: Decodable { let block: SchemaBlock }
private struct SchemaBlock: Decodable {
    let attributes: [String: Attribute]?
    let block_types: [String: NestedBlock]?
}
private struct Attribute: Decodable {
    let type: JSONValue?
    let required: Bool?
    let optional: Bool?
    let computed: Bool?
    let sensitive: Bool?
}
private struct NestedBlock: Decodable {
    let nesting_mode: String
    let block: SchemaBlock
    let min_items: Int?
    let max_items: Int?
}

/// Generates standalone Swift bindings from `terraform providers schema -json`.
/// The exported schema contains structural types, not every provider-side semantic validator.
public enum SchemaGenerator {
    public static func generate(from data: Data, provider source: String? = nil,
                                prefix: String? = nil, version: String, includeTypes: Set<String> = []) throws -> String {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.format_version.split(separator: ".").first == "1" else {
            throw NidoError("Unsupported provider schema format \(document.format_version); expected 1.x")
        }
        let source: String = try source ?? {
            guard document.provider_schemas.count == 1, let source = document.provider_schemas.keys.first else {
                throw NidoError("Select a provider with --provider; schema contains \(document.provider_schemas.keys.sorted())")
            }
            return source
        }()
        guard let schema = document.provider_schemas[source], let localName = source.split(separator: "/").last else {
            throw NidoError("Provider not found in schema: \(source)")
        }
        guard !source.hasPrefix("terraform.io/builtin/") else {
            throw NidoError("Built-in Terraform providers are not installed as versioned plugins; use Nido's TerraformData API")
        }
        let available = Set((schema.resource_schemas ?? [:]).keys).union((schema.data_source_schemas ?? [:]).keys)
        guard includeTypes.isSubset(of: available) else {
            throw NidoError("Types not found in schema: \(includeTypes.subtracting(available).sorted())")
        }
        let prefix = prefix ?? String(localName).capitalized
        guard prefix.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw NidoError("Prefix must be a Swift identifier")
        }
        let generator = Generator(prefix: prefix, localName: String(localName), source: source, version: version)
        return try generator.generate(schema, includeTypes: includeTypes)
    }
}

private struct Field {
    let key: String
    let name: String
    let type: String
    let required: Bool
    let expression: String
    let count: String?
    let minimum: Int
    let maximum: Int?
}

private final class Generator {
    let prefix: String, localName: String, source: String, version: String
    var declarations: [String] = []
    var typeNames = Set<String>()
    init(prefix: String, localName: String, source: String, version: String) {
        self.prefix = prefix; self.localName = localName; self.source = source; self.version = version
    }

    func generate(_ schema: ProviderSchema, includeTypes: Set<String>) throws -> String {
        let providerType = prefix + "Provider"
        try register(providerType)
        let providerFields = try fields(schema.provider?.block, path: providerType)
        let params = parameters(providerFields)
        declarations.append("""
        public struct \(providerType): Component {
            public let provider: Provider
            public init(alias: String? = nil\(params.isEmpty ? "" : ", " + params)) {
        \(configuration(providerFields, indent: "        "))
                provider = Provider(.init(\(quote(localName)), source: \(quote(source)), version: \(quote(version))), alias: alias, configuration: attributes, issues: issues)
            }
            public var blocks: [Block] { provider.blocks }
        }
        """)
        for (kind, schemas) in [("resource", schema.resource_schemas ?? [:]), ("data", schema.data_source_schemas ?? [:])] {
            for key in schemas.keys.sorted() where includeTypes.isEmpty || includeTypes.contains(key) {
                let name = prefix + (kind == "data" ? "Data" : "") + pascal(key.hasPrefix(localName + "_") ? String(key.dropFirst(localName.count + 1)) : key)
                try register(name); try register(name + "Kind")
                let block = schemas[key]!.block
                let inputFields = try fields(block, path: name)
                let params = parameters(inputFields)
                var outputs: [String] = []
                let outputNames = (block.attributes ?? [:]).keys.map(identifier)
                guard Set(outputNames).count == outputNames.count else { throw NidoError("Computed field name collision at \(name)") }
                // Types for configurable attributes were already emitted by fields().
                for key in (block.attributes ?? [:]).keys.sorted() {
                    let attribute = block.attributes![key]!
                    let configurable = attribute.required == true || attribute.optional == true
                    let type = try swiftType(attribute.type ?? .string("dynamic"), path: name + pascal(key), emit: !configurable)
                    outputs.append("    public var \(identifier(key)): Value<\(type)> { resource.unsafeAttribute(\(quote(key)), sensitive: \(attribute.sensitive == true)) }")
                }
                declarations.append("""
                public enum \(name)Kind: ResourceKind {
                    public static let terraformType = \(quote(key))
                    public static let blockKind = BlockKind.\(kind)
                }
                public struct \(name): Component {
                    public let resource: Resource<\(name)Kind>
                    public init(_ logicalName: String, provider: \(providerType)\(params.isEmpty ? "" : ", " + params), options: \(kind == "data" ? "DataSourceOptions" : "ResourceOptions") = .init()) {
                \(configuration(inputFields, indent: "        "))
                        resource = Resource(logicalName, attributes: attributes, provider: provider.provider, options: \(kind == "data" ? ".init(dependsOn: options.dependsOn)" : "options"), issues: issues)
                    }
                    public var blocks: [Block] { resource.blocks }
                    public var dependency: Dependency { resource.dependency }
                \(outputs.joined(separator: "\n"))
                }
                """)
            }
        }
        return "// Generated by nido provider generate. Do not edit.\nimport Nido\n\n" + declarations.joined(separator: "\n\n") + "\n"
    }

    func register(_ name: String) throws {
        guard typeNames.insert(name).inserted else { throw NidoError("Schema generates duplicate Swift type \(name); select another prefix or report this schema") }
    }

    func fields(_ block: SchemaBlock?, path: String) throws -> [Field] {
        guard let block else { return [] }
        var result: [Field] = []
        for key in (block.attributes ?? [:]).keys.sorted() {
            let attribute = block.attributes![key]!
            guard attribute.required == true || attribute.optional == true else { continue }
            let type = try swiftType(attribute.type ?? .string("dynamic"), path: path + pascal(key))
            let name = identifier(key)
            result.append(Field(key: key, name: name, type: "Value<\(type)>", required: attribute.required == true,
                                expression: name + (attribute.sensitive == true ? ".sensitive()" : "") + ".erased",
                                count: nil, minimum: 0, maximum: nil))
        }
        for key in (block.block_types ?? [:]).keys.sorted() {
            let nested = block.block_types![key]!
            let type = path + pascal(key) + "Block"
            try object(type, fields: fields(nested.block, path: type))
            let name = identifier(key), minimum = nested.min_items ?? 0
            let swift: String, expression: String, count: String?
            switch nested.nesting_mode {
            case "single", "group": (swift, expression, count) = (type, name + ".value.erased", nil)
            case "list", "set":
                if nested.max_items == 1 {
                    (swift, expression, count) = (type, ".array([\(name).value.erased])", nil)
                } else if minimum > 0 {
                    (swift, expression, count) = ("NonEmpty<\(type)>", ".array(\(name).elements.map { $0.value.erased })", name + ".elements.count")
                } else {
                    (swift, expression, count) = ("[\(type)]", ".array(\(name).map { $0.value.erased })", name + ".count")
                }
            case "map": (swift, expression, count) = ("[String: \(type)]", ".object(\(name).mapValues { $0.value.erased })", name + ".count")
            default: throw NidoError("Unsupported nesting mode \(nested.nesting_mode) at \(path).\(key)")
            }
            result.append(Field(key: key, name: name, type: swift, required: minimum > 0,
                                expression: expression, count: count, minimum: minimum, maximum: nested.max_items))
        }
        let names = result.map(\.name)
        guard Set(names).count == names.count else { throw NidoError("Schema field names collide after Swift conversion at \(path)") }
        return result
    }

    func swiftType(_ type: JSONValue, path: String, emit: Bool = true) throws -> String {
        switch type {
        case .string("string"): return "String"
        case .string("number"): return "Double"
        case .string("bool"): return "Bool"
        case .string("dynamic"): return "JSONValue"
        case .array(let parts) where parts.count == 2:
            switch parts[0] {
            case .string("list"), .string("set"): return "[\(try swiftType(parts[1], path: path + "Element", emit: emit))]"
            case .string("map"): return "[String: \(try swiftType(parts[1], path: path + "Element", emit: emit))]"
            case .string("object"):
                guard case .object(let attrs) = parts[1] else { throw NidoError("Invalid object type at \(path)") }
                let name = path + "Object"
                if emit {
                    let fields = try attrs.keys.sorted().map { key in
                        Field(key: key, name: identifier(key), type: "Value<\(try swiftType(attrs[key]!, path: name + pascal(key)))>",
                              required: true, expression: identifier(key) + ".erased", count: nil, minimum: 0, maximum: nil)
                    }
                    try object(name, fields: fields)
                }
                return name
            case .string("tuple"):
                guard case .array(let elements) = parts[1] else { throw NidoError("Invalid tuple at \(path)") }
                let name = path + "Tuple"
                if emit {
                    try register(name)
                    let types = try elements.enumerated().map { try swiftType($1, path: name + "Element\($0)") }
                    let properties = types.enumerated().map { "    public let element\($0): Value<\($1)>" }.joined(separator: "\n")
                    let params = types.enumerated().map { "element\($0): Value<\($1)>" }.joined(separator: ", ")
                    let assigns = types.indices.map { "        self.element\($0) = element\($0)" }.joined(separator: "\n")
                    let values = types.indices.map { "element\($0).erased" }.joined(separator: ", ")
                    declarations.append("public struct \(name): NidoTuple {\n\(properties)\n    public init(\(params)) {\n\(assigns)\n    }\n    public var elements: [AnyValue] { [\(values)] }\n}")
                }
                return name
            default: break
            }
        default: break
        }
        throw NidoError("Unsupported Terraform type at \(path): \(type)")
    }

    func object(_ name: String, fields: [Field]) throws {
        try register(name)
        guard Set(fields.map(\.name)).count == fields.count else { throw NidoError("Object field name collision at \(name)") }
        declarations.append("""
        public struct \(name): NidoObject {
            public let fields: [String: AnyValue]
            public let validationIssues: [String]
            public init(\(parameters(fields))) {
        \(configuration(fields, indent: "        "))
                self.fields = attributes
                self.validationIssues = issues
            }
        }
        """)
        let accessors = fields.filter { $0.type.hasPrefix("Value<") }.map { field in
            "    public var \(field.name): \(field.type) { unsafeField(\(quote(field.key))) }"
        }
        if !accessors.isEmpty {
            declarations.append("extension Value where T == \(name) {\n\(accessors.joined(separator: "\n"))\n}")
        }
    }

    func parameters(_ fields: [Field]) -> String {
        fields.map { "\($0.name): \($0.type)\($0.required ? "" : "? = nil")" }.joined(separator: ", ")
    }

    func configuration(_ fields: [Field], indent: String) -> String {
        let validatesCounts = fields.contains { $0.count != nil && ($0.minimum > 1 || $0.maximum != nil) }
        var lines = ["\(fields.isEmpty ? "let" : "var") attributes: [String: AnyValue] = [:]",
                     "\(validatesCounts ? "var" : "let") issues: [String] = []"]
        for field in fields {
            if !field.required { lines.append("if let \(field.name) {") }
            let pad = field.required ? "" : "    "
            lines.append(pad + "attributes[\(quote(field.key))] = \(field.expression)")
            if let count = field.count {
                if field.minimum > 1 { lines.append(pad + "if \(count) < \(field.minimum) { issues.append(\(quote(field.key + " requires at least \(field.minimum) blocks"))) }") }
                if let max = field.maximum { lines.append(pad + "if \(count) > \(max) { issues.append(\(quote(field.key + " accepts at most \(max) blocks"))) }") }
            }
            if !field.required { lines.append("}") }
        }
        // No mutable collection is exposed by the generated type.
        return lines.map { indent + $0 }.joined(separator: "\n")
    }

    let reserved: Set<String> = ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while", "as", "Any", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try", "async", "await", "some", "any", "Type", "resource", "blocks", "dependency", "provider", "options", "logicalName", "alias", "fields", "value", "validationIssues", "attributes", "issues"]
    func identifier(_ s: String) -> String {
        let parts = s.split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }.map(String.init)
        var name = (parts.first ?? "field") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        if name.first?.isNumber == true { name = "field" + name }
        if reserved.contains(name) { name += "_" }
        return name
    }
    func pascal(_ s: String) -> String {
        let v = identifier(s)
        return v.prefix(1).uppercased() + v.dropFirst()
    }
    func quote(_ s: String) -> String {
        "\"" + s.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 34: return "\\\""
            case 92: return "\\\\"
            case 0...31, 127: return "\\u{\(String(scalar.value, radix: 16))}"
            default: return String(scalar)
            }
        }.joined() + "\""
    }
}
