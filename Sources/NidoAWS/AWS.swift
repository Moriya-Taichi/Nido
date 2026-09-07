import Nido

public protocol AWSRegion: Sendable { static var name: String { get } }
public enum APNortheast1: AWSRegion { public static let name = "ap-northeast-1" }
public enum USWest2: AWSRegion { public static let name = "us-west-2" }
public enum USEast1: AWSRegion { public static let name = "us-east-1" }
public enum EUWest1: AWSRegion { public static let name = "eu-west-1" }

public struct AWSProvider<Region: AWSRegion>: Component {
    public let provider: Provider
    public init(alias: String? = nil, version: String = "~> 6.0", profile: Value<String>? = nil) {
        var config: [String: AnyValue] = ["region": .literal(Region.name)]
        if let profile { config["profile"] = profile.erased }
        provider = Provider(.init("aws", source: "hashicorp/aws", version: version),
                            alias: alias, configuration: config)
    }
    public var blocks: [Block] { provider.blocks }
}

/// Declare a distinct marker enum for each VPC. Reusing a marker is checked again during synthesis.
public protocol NetworkScope: Sendable {}
public enum VPCID<R: AWSRegion, N: NetworkScope>: Sendable {}
public enum SubnetID<R: AWSRegion, N: NetworkScope>: Sendable {}
public enum SecurityGroupID<R: AWSRegion, N: NetworkScope>: Sendable {}

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

public enum VPCResource: ResourceKind { public static let terraformType = "aws_vpc" }
public struct VPC<R: AWSRegion, N: NetworkScope>: Component {
    public let resource: Resource<VPCResource>
    public let provider: AWSProvider<R>
    public let cidr: IPv4CIDR
    public init(_ name: String, cidr: IPv4CIDR, provider: AWSProvider<R>, scope: N.Type,
                tags: Value<[String: String]> = .literal([:]), options: ResourceOptions = .init()) {
        self.provider = provider; self.cidr = cidr
        resource = Resource(name, attributes: ["cidr_block": .literal(cidr.description),
                            "enable_dns_support": .literal(true), "enable_dns_hostnames": .literal(true), "tags": tags.erased],
                            provider: provider.provider, options: options,
                            issues: (16...28).contains(cidr.prefix) ? [] : ["AWS VPC IPv4 prefix must be /16 through /28"])
    }
    public var id: Value<VPCID<R, N>> { resource.unsafeAttribute("id") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}

public enum SubnetResource: ResourceKind { public static let terraformType = "aws_subnet" }
public struct Subnet<R: AWSRegion, N: NetworkScope>: Component {
    public let resource: Resource<SubnetResource>
    public let vpc: VPC<R, N>
    public init(_ name: String, vpc: VPC<R, N>, cidr: IPv4CIDR,
                publicIPOnLaunch: Value<Bool> = false, options: ResourceOptions = .init()) {
        self.vpc = vpc
        var issues: [String] = []
        if !vpc.cidr.contains(cidr) { issues.append("Subnet CIDR \(cidr.description) is outside VPC \(vpc.cidr.description)") }
        if !(16...28).contains(cidr.prefix) { issues.append("AWS subnet IPv4 prefix must be /16 through /28") }
        resource = Resource(name, attributes: ["vpc_id": vpc.id.erased, "cidr_block": .literal(cidr.description),
                            "map_public_ip_on_launch": publicIPOnLaunch.erased], provider: vpc.provider.provider,
                            options: options, issues: issues)
    }
    public var id: Value<SubnetID<R, N>> { resource.unsafeAttribute("id") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
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
public enum SecurityRule: Sendable {
    case tcp(PortRange, from: IPv4CIDR)
    case udp(PortRange, from: IPv4CIDR)
    case allTraffic(from: IPv4CIDR)
    var value: AnyValue {
        let proto: String, from: Int, to: Int, cidr: IPv4CIDR
        switch self {
        case .tcp(let p, let c): (proto, from, to, cidr) = ("tcp", p.lower, p.upper, c)
        case .udp(let p, let c): (proto, from, to, cidr) = ("udp", p.lower, p.upper, c)
        case .allTraffic(let c): (proto, from, to, cidr) = ("-1", 0, 0, c)
        }
        // The AWS provider's ingress/egress attributes use its historical attributes-as-blocks form.
        return .object(["protocol": .literal(proto), "from_port": .literal(from), "to_port": .literal(to),
                        "cidr_blocks": .literal([cidr.description]), "ipv6_cidr_blocks": .literal([String]()),
                        "prefix_list_ids": .literal([String]()), "security_groups": .literal([String]()),
                        "self": .literal(false), "description": .literal("")])
    }
}

public enum SecurityGroupResource: ResourceKind { public static let terraformType = "aws_security_group" }
public struct SecurityGroup<R: AWSRegion, N: NetworkScope>: Component {
    public let resource: Resource<SecurityGroupResource>
    public let vpc: VPC<R, N>
    public init(_ name: String, vpc: VPC<R, N>, description: Value<String>,
                ingress: [SecurityRule] = [], egress: [SecurityRule] = [], options: ResourceOptions = .init()) {
        self.vpc = vpc
        resource = Resource(name, attributes: ["vpc_id": vpc.id.erased, "description": description.erased,
                            "ingress": .array(ingress.map(\.value)), "egress": .array(egress.map(\.value))],
                            provider: vpc.provider.provider, options: options)
    }
    public var id: Value<SecurityGroupID<R, N>> { resource.unsafeAttribute("id") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}

public protocol CPUArchitecture: Sendable { static var name: String { get } }
public enum ARM64: CPUArchitecture { public static let name = "arm64" }
public enum X86_64: CPUArchitecture { public static let name = "x86_64" }
public struct InstanceType<A: CPUArchitecture>: Sendable {
    public let name: String
    private init(_ name: String) { self.name = name }
    /// Use only after verifying an instance type's architecture in the EC2 documentation.
    public static func unchecked(_ name: String) -> Self { Self(name) }
}
extension InstanceType where A == ARM64 {
    public static var t4gMicro: Self { Self("t4g.micro") }
    public static var m7gLarge: Self { Self("m7g.large") }
}
extension InstanceType where A == X86_64 {
    public static var t3Micro: Self { Self("t3.micro") }
    public static var m7iLarge: Self { Self("m7i.large") }
}

public enum AMIResource: ResourceKind {
    public static let terraformType = "aws_ami"
    public static let blockKind = BlockKind.data
}
public struct AMI<R: AWSRegion, A: CPUArchitecture>: Component {
    public let resource: Resource<AMIResource>
    public let provider: AWSProvider<R>
    /// The architecture is enforced by a real EC2 filter, not an assertion about an arbitrary AMI ID.
    public init(_ name: String, provider: AWSProvider<R>, architecture: A.Type,
                owners: Value<[String]>, namePattern: Value<String>, mostRecent: Value<Bool> = true) {
        self.provider = provider
        resource = Resource(name, attributes: ["owners": owners.erased, "most_recent": mostRecent.erased,
            "filter": .array([
                .object(["name": .literal("name"), "values": Value<[String]>.list([namePattern]).erased]),
                .object(["name": .literal("architecture"), "values": .literal([A.name])]),
                .object(["name": .literal("virtualization-type"), "values": .literal(["hvm"])]),
            ])], provider: provider.provider)
    }
    public var id: Value<String> { resource.unsafeAttribute("id") }
    public var blocks: [Block] { resource.blocks }
}

public enum EC2InstanceResource: ResourceKind { public static let terraformType = "aws_instance" }
public struct EC2Instance<R: AWSRegion, N: NetworkScope, A: CPUArchitecture>: Component {
    public let resource: Resource<EC2InstanceResource>
    public init(_ name: String, image: AMI<R, A>, instanceType: InstanceType<A>,
                subnet: Subnet<R, N>, securityGroups: [SecurityGroup<R, N>] = [],
                tags: Value<[String: String]> = .literal([:]), options: ResourceOptions = .init()) {
        var issues: [String] = []
        if securityGroups.contains(where: { $0.vpc.dependency != subnet.vpc.dependency }) {
            issues.append("Security groups and subnet must belong to the same VPC; use a distinct NetworkScope for each VPC")
        }
        if image.provider.provider.reference != subnet.vpc.provider.provider.reference {
            issues.append("AMI and subnet must use the same provider configuration")
        }
        resource = Resource(name, attributes: ["ami": image.id.erased, "instance_type": .literal(instanceType.name),
                            "subnet_id": subnet.id.erased,
                            "vpc_security_group_ids": Value<[SecurityGroupID<R, N>]>.list(securityGroups.map(\.id)).erased,
                            "tags": tags.erased], provider: subnet.vpc.provider.provider, options: options, issues: issues)
    }
    public var id: Value<String> { resource.unsafeAttribute("id") }
    public var publicIP: Value<String> { resource.unsafeAttribute("public_ip") }
    public var privateIP: Value<String> { resource.unsafeAttribute("private_ip") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}

public enum S3BucketResource: ResourceKind { public static let terraformType = "aws_s3_bucket" }
public struct S3Bucket<R: AWSRegion>: Component {
    public let resource: Resource<S3BucketResource>
    public init(_ name: String, bucket: Value<String>, provider: AWSProvider<R>,
                tags: Value<[String: String]> = .literal([:]), options: ResourceOptions = .init()) {
        resource = Resource(name, attributes: ["bucket": bucket.erased, "tags": tags.erased],
                            provider: provider.provider, options: options)
    }
    public var id: Value<String> { resource.unsafeAttribute("id") }
    public var arn: Value<String> { resource.unsafeAttribute("arn") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
