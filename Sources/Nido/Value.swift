import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String), integer(Int), number(Double), bool(Bool)
    case array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // Terraform JSON strings in expression positions are templates, even inside collections.
    var escapedLiteral: JSONValue {
        switch self {
        case .string(let s): return .string(s.replacingOccurrences(of: "${", with: "$${")
            .replacingOccurrences(of: "%{", with: "%%{"))
        case .array(let a): return .array(a.map(\.escapedLiteral))
        case .object(let o): return .object(o.mapValues(\.escapedLiteral))
        default: return self
        }
    }

    var validationIssues: [String] {
        switch self {
        case .number(let n): n.isFinite ? [] : ["Terraform numbers must be finite"]
        case .array(let a): a.flatMap(\.validationIssues)
        case .object(let o): o.keys.sorted().flatMap { o[$0]!.validationIssues }
        default: []
        }
    }
}

public protocol TerraformLiteral: Sendable {
    static var terraformType: String { get }
    var terraformLiteral: JSONValue { get }
}
extension String: TerraformLiteral {
    public static var terraformType: String { "string" }
    public var terraformLiteral: JSONValue { .string(self) }
}
extension Int: TerraformLiteral {
    public static var terraformType: String { "number" }
    public var terraformLiteral: JSONValue { .integer(self) }
}
extension Double: TerraformLiteral {
    public static var terraformType: String { "number" }
    public var terraformLiteral: JSONValue { .number(self) }
}
extension Bool: TerraformLiteral {
    public static var terraformType: String { "bool" }
    public var terraformLiteral: JSONValue { .bool(self) }
}
extension JSONValue: TerraformLiteral {
    public static var terraformType: String { "any" }
    public var terraformLiteral: JSONValue { self }
}
extension Array: TerraformLiteral where Element: TerraformLiteral {
    public static var terraformType: String { "list(\(Element.terraformType))" }
    public var terraformLiteral: JSONValue { .array(map(\.terraformLiteral)) }
}
extension Dictionary: TerraformLiteral where Key == String, Value: TerraformLiteral {
    public static var terraformType: String { "map(\(Value.terraformType))" }
    public var terraformLiteral: JSONValue { .object(mapValues(\.terraformLiteral)) }
}

indirect enum Expression: Sendable {
    case literal(JSONValue)
    case reference(String, Set<String>)
    case array([Expression])
    case object([String: Expression])
    case validated(Expression, [String])
    case field(Expression, String)

    var json: JSONValue {
        switch self {
        case .literal(let v): v.escapedLiteral
        case .reference(let source, _): .string("${\(source)}")
        case .array(let a): .array(a.map(\.json))
        case .object(let o): .object(o.mapValues(\.json))
        case .validated(let expression, _): expression.json
        case .field(let expression, let name): .string("${(\(expression.hcl)).\(name)}")
        }
    }

    var dependencies: Set<String> {
        switch self {
        case .literal: []
        case .reference(_, let d): d
        case .array(let a): a.reduce(into: []) { $0.formUnion($1.dependencies) }
        case .object(let o): o.values.reduce(into: []) { $0.formUnion($1.dependencies) }
        case .validated(let expression, _): expression.dependencies
        case .field(let expression, _): expression.dependencies
        }
    }

    var issues: [String] {
        switch self {
        case .literal(let v): v.validationIssues
        case .reference: []
        case .array(let a): a.flatMap(\.issues)
        case .object(let o): o.keys.sorted().flatMap { o[$0]!.issues }
        case .validated(let expression, let issues): issues + expression.issues
        case .field(let expression, _): expression.issues
        }
    }

    var hcl: String {
        switch self {
        case .reference(let source, _): return source
        case .literal(let v): return String(data: try! v.escapedLiteral.encoded(), encoding: .utf8)!
        case .array(let a): return "[" + a.map(\.hcl).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { key in
            let quoted = String(data: try! JSONEncoder().encode(key), encoding: .utf8)!
            return "\(quoted) = \(o[key]!.hcl)"
        }.joined(separator: ", ") + "}"
        case .validated(let expression, _): return expression.hcl
        case .field(let expression, let name): return "(\(expression.hcl)).\(name)"
        }
    }
}

/// A value that may become known only during apply. T is retained by the Swift compiler.
public struct Value<T>: Sendable {
    let expression: Expression
    public let isSensitive: Bool

    init(_ expression: Expression, sensitive: Bool = false) {
        self.expression = expression
        isSensitive = sensitive
    }

    public static func literal(_ value: T) -> Self where T: TerraformLiteral {
        Self(.literal(value.terraformLiteral))
    }

    /// Explicit escape hatch: the caller must verify the expression's type and list all dependencies.
    public static func unsafeExpression(_ source: String, dependencies: [Dependency] = [],
                                        sensitive: Bool = false) -> Self {
        Self(.reference(source, Set(dependencies.map(\.address))), sensitive: sensitive)
    }

    public func sensitive() -> Self { Self(expression, sensitive: true) }
    public var erased: AnyValue { AnyValue(expression: expression, isSensitive: isSensitive) }

    /// Used by generated object accessors. The field's schema determines U.
    public func unsafeField<U>(_ name: String, as: U.Type = U.self) -> Value<U> {
        Value<U>(.field(expression, name), sensitive: isSensitive)
    }

    public static func list<E>(_ elements: [Value<E>]) -> Self where T == [E] {
        Self(.array(elements.map(\.expression)), sensitive: elements.contains(where: \.isSensitive))
    }

    public static func map<E>(_ elements: [String: Value<E>]) -> Self where T == [String: E] {
        Self(.object(elements.mapValues(\.expression)), sensitive: elements.values.contains(where: \.isSensitive))
    }
}

extension Value: ExpressibleByStringLiteral, ExpressibleByExtendedGraphemeClusterLiteral,
    ExpressibleByUnicodeScalarLiteral where T == String {
    public init(stringLiteral value: String) { self = .literal(value) }
}
extension Value: ExpressibleByIntegerLiteral where T == Int {
    public init(integerLiteral value: Int) { self = .literal(value) }
}
extension Value: ExpressibleByFloatLiteral where T == Double {
    public init(floatLiteral value: Double) { self = .literal(value) }
}
extension Value: ExpressibleByBooleanLiteral where T == Bool {
    public init(booleanLiteral value: Bool) { self = .literal(value) }
}

/// Type erasure is limited to the serialization boundary; prefer generated or curated resource APIs.
public struct AnyValue: Sendable {
    let expression: Expression
    public let isSensitive: Bool
    public static func literal<T: TerraformLiteral>(_ value: T) -> Self { Value<T>.literal(value).erased }
    public static func object(_ fields: [String: AnyValue]) -> Self {
        Self(expression: .object(fields.mapValues(\.expression)), isSensitive: fields.values.contains(where: \.isSensitive))
    }
    public static func array(_ values: [AnyValue]) -> Self {
        Self(expression: .array(values.map(\.expression)), isSensitive: values.contains(where: \.isSensitive))
    }
}

/// Generated object types implement this to retain nested field types and expression dependencies.
public protocol NidoObject: Sendable {
    var fields: [String: AnyValue] { get }
    var validationIssues: [String] { get }
}
extension NidoObject {
    public var validationIssues: [String] { [] }
    public var value: Value<Self> {
        Value(.validated(.object(fields.mapValues(\.expression)), validationIssues),
              sensitive: fields.values.contains(where: \.isSensitive))
    }
}

public protocol NidoTuple: Sendable { var elements: [AnyValue] { get } }
extension NidoTuple {
    public var value: Value<Self> {
        Value(.array(elements.map(\.expression)), sensitive: elements.contains(where: \.isSensitive))
    }
}

public struct NonEmpty<Element: Sendable>: Sendable {
    public let elements: [Element]
    public init(_ first: Element, rest: [Element] = []) { elements = [first] + rest }
}
