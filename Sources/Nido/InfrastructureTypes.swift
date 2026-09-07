/// Shared value types; cloud-specific resources keep their own identity types.
public protocol NetworkScope: Sendable {}

public struct IPv4CIDR: Sendable, Equatable {
    public let description: String
    public let prefix: Int
    private let network: UInt32
    public init(_ text: String) throws {
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let prefix = Int(pieces[1]), (0...32).contains(prefix) else {
            throw NidoError("Invalid IPv4 CIDR: \(text)")
        }
        let octets = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { throw NidoError("Invalid IPv4 CIDR: \(text)") }
        var address: UInt32 = 0
        for octet in octets {
            guard !octet.isEmpty, octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt32(octet), value <= 255 else { throw NidoError("Invalid IPv4 CIDR: \(text)") }
            address = (address << 8) | value
        }
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - prefix)
        guard address & mask == address else { throw NidoError("CIDR must specify a network address: \(text)") }
        self.prefix = prefix; network = address
        description = "\((address >> 24) & 255).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)/\(prefix)"
    }
    public func contains(_ other: Self) -> Bool {
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - prefix)
        return prefix <= other.prefix && other.network & mask == network
    }
}

public struct PortRange: Sendable {
    public let lower: Int
    public let upper: Int
    public init(_ port: Int) throws { try self.init(port...port) }
    public init(_ ports: ClosedRange<Int>) throws {
        guard ports.lowerBound >= 0, ports.upperBound <= 65535 else { throw NidoError("Ports must be between 0 and 65535") }
        lower = ports.lowerBound; upper = ports.upperBound
    }
}
public protocol CPUArchitecture: Sendable { static var name: String { get } }
public enum ARM64: CPUArchitecture { public static let name = "arm64" }
public enum X86_64: CPUArchitecture { public static let name = "x86_64" }
