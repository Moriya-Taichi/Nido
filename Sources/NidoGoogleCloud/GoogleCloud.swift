import Nido

public protocol GoogleProjectScope: Sendable {}
public protocol GoogleRegion: Sendable { static var name: String { get } }
public enum AsiaNortheast1: GoogleRegion { public static let name = "asia-northeast1" }
public enum USCentral1: GoogleRegion { public static let name = "us-central1" }
public enum EuropeWest1: GoogleRegion { public static let name = "europe-west1" }

/// Global VPCs use this project provider; regional resources specify their own region.
/// Authentication uses the Google provider's standard ADC/environment mechanisms.
public struct GoogleProvider<P: GoogleProjectScope>: Component {
    public let provider: Provider
    public let project: Value<String>
    public init(project: Value<String>, scope: P.Type, alias: String? = nil, version: String = "~> 6.0") {
        self.project = project
        provider = Provider(.init("google", source: "hashicorp/google", version: version), alias: alias,
                            configuration: ["project": project.erased])
    }
    public var blocks: [Block] { provider.blocks }
}
public struct GoogleZone<R: GoogleRegion>: Sendable {
    public let name: String
    public init(_ name: String) throws {
        let suffix = name.dropFirst(R.name.count + 1)
        guard name.hasPrefix(R.name + "-"), suffix.count == 1, suffix.allSatisfy({ $0 >= "a" && $0 <= "z" }) else {
            throw NidoError("Zone \(name) must belong to region \(R.name)")
        }
        self.name = name
    }
}
public enum GoogleNetworkID<P: GoogleProjectScope, N: NetworkScope>: Sendable {}
public enum GoogleSubnetID<R: GoogleRegion, P: GoogleProjectScope, N: NetworkScope>: Sendable {}
public enum GoogleNetworkKind: ResourceKind { public static let terraformType = "google_compute_network" }
public struct GoogleNetwork<P: GoogleProjectScope, N: NetworkScope>: Component {
    public let resource: Resource<GoogleNetworkKind>
    public let provider: GoogleProvider<P>
    public init(_ name: String, networkName: Value<String>, provider: GoogleProvider<P>, scope: N.Type,
                options: ResourceOptions = .init()) {
        self.provider = provider
        resource = Resource(name, attributes: ["name": networkName.erased, "project": provider.project.erased,
                            "auto_create_subnetworks": .literal(false)], provider: provider.provider, options: options)
    }
    public var id: Value<GoogleNetworkID<P, N>> { resource.unsafeAttribute("self_link") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
public enum GoogleSubnetworkKind: ResourceKind { public static let terraformType = "google_compute_subnetwork" }
public struct GoogleSubnetwork<R: GoogleRegion, P: GoogleProjectScope, N: NetworkScope>: Component {
    public let resource: Resource<GoogleSubnetworkKind>
    public let network: GoogleNetwork<P, N>
    public init(_ name: String, subnetName: Value<String>, network: GoogleNetwork<P, N>, region: R.Type,
                cidr: IPv4CIDR, options: ResourceOptions = .init()) {
        self.network = network
        resource = Resource(name, attributes: ["name": subnetName.erased, "project": network.provider.project.erased,
                            "region": .literal(R.name), "network": network.id.erased,
                            "ip_cidr_range": .literal(cidr.description), "private_ip_google_access": .literal(true)],
                            provider: network.provider.provider, options: options,
                            issues: (4...29).contains(cidr.prefix) ? [] : ["Google IPv4 subnet must be /4 through /29"])
    }
    public var id: Value<GoogleSubnetID<R, P, N>> { resource.unsafeAttribute("self_link") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
public struct GoogleFirewallAllow: Sendable {
    public enum Transport: String, Sendable { case tcp, udp }
    let transport: Transport, ports: PortRange
    public init(_ transport: Transport, ports: PortRange) { self.transport = transport; self.ports = ports }
}
public enum GoogleFirewallKind: ResourceKind { public static let terraformType = "google_compute_firewall" }
public struct GoogleFirewall<P: GoogleProjectScope, N: NetworkScope>: Component {
    public let resource: Resource<GoogleFirewallKind>
    public let network: GoogleNetwork<P, N>
    public let targetTag: String
    public init(_ name: String, firewallName: Value<String>, network: GoogleNetwork<P, N>, targetTag: String,
                source: IPv4CIDR, allow: GoogleFirewallAllow, options: ResourceOptions = .init()) {
        self.network = network; self.targetTag = targetTag
        let validTag = !targetTag.isEmpty && targetTag.count <= 63 && targetTag.first!.isASCII && targetTag.first!.isLetter
            && targetTag.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") } && targetTag.last != "-"
        resource = Resource(name, attributes: ["name": firewallName.erased, "project": network.provider.project.erased,
            "network": network.id.erased, "direction": .literal("INGRESS"), "source_ranges": .literal([source.description]),
            "target_tags": .literal([targetTag]), "allow": .array([.object([
                "protocol": .literal(allow.transport.rawValue),
                "ports": .literal([allow.ports.lower == allow.ports.upper ? "\(allow.ports.lower)" : "\(allow.ports.lower)-\(allow.ports.upper)"]),
            ])])], provider: network.provider.provider, options: options,
            issues: validTag ? [] : ["Google firewall target tag must be a lowercase RFC1035 name"])
    }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
public struct GoogleMachineType<A: CPUArchitecture>: Sendable {
    public let name: String
    private init(_ name: String) { self.name = name }
    public static func unchecked(_ name: String) -> Self { Self(name) }
}
extension GoogleMachineType where A == X86_64 { public static var e2Small: Self { Self("e2-small") } }
extension GoogleMachineType where A == ARM64 { public static var t2aStandard1: Self { Self("t2a-standard-1") } }
public struct GoogleImage<A: CPUArchitecture>: Sendable {
    public let name: String
    private init(_ name: String) { self.name = name }
    /// Verify the architecture of a custom image before using this escape hatch.
    public static func unchecked(_ name: String) -> Self { Self(name) }
}
extension GoogleImage where A == X86_64 {
    public static var debian12: Self { Self("projects/debian-cloud/global/images/family/debian-12") }
}
extension GoogleImage where A == ARM64 {
    public static var debian12: Self { Self("projects/debian-cloud/global/images/family/debian-12-arm64") }
}
public enum GoogleInstanceKind: ResourceKind { public static let terraformType = "google_compute_instance" }
public struct GoogleComputeInstance<R: GoogleRegion, P: GoogleProjectScope, N: NetworkScope, A: CPUArchitecture>: Component {
    public let resource: Resource<GoogleInstanceKind>
    public init(_ name: String, instanceName: Value<String>, subnet: GoogleSubnetwork<R, P, N>, zone: GoogleZone<R>,
                machineType: GoogleMachineType<A>, image: GoogleImage<A>, firewalls: [GoogleFirewall<P, N>] = [],
                options: ResourceOptions = .init()) {
        var options = options
        options.dependsOn += firewalls.map(\.dependency)
        resource = Resource(name, attributes: ["name": instanceName.erased, "project": subnet.network.provider.project.erased,
            "zone": .literal(zone.name), "machine_type": .literal(machineType.name),
            "boot_disk": .array([.object(["initialize_params": .array([.object(["image": .literal(image.name)])])])]),
            "network_interface": .array([.object(["subnetwork": subnet.id.erased,
                                                "nic_type": .literal(A.name == ARM64.name ? "GVNIC" : "VIRTIO_NET")])]),
            "tags": .literal(Array(Set(firewalls.map(\.targetTag))).sorted()),
            "metadata": .literal(["enable-oslogin": "TRUE"]),
        ], provider: subnet.network.provider.provider, options: options,
            issues: firewalls.allSatisfy { $0.network.dependency == subnet.network.dependency } ? [] : ["Google instance firewall and subnet must use the same VPC"])
    }
    public var id: Value<String> { resource.unsafeAttribute("id") }
    public var selfLink: Value<String> { resource.unsafeAttribute("self_link") }
    public var privateIP: Value<String> { resource.unsafeAttribute("network_interface[0].network_ip") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
public enum GoogleBucketKind: ResourceKind { public static let terraformType = "google_storage_bucket" }
public enum GoogleStorageClass: String, Sendable { case standard = "STANDARD", nearline = "NEARLINE", coldline = "COLDLINE", archive = "ARCHIVE" }
public struct GoogleStorageBucket<R: GoogleRegion, P: GoogleProjectScope>: Component {
    public let resource: Resource<GoogleBucketKind>
    public init(_ name: String, bucketName: Value<String>, region: R.Type, provider: GoogleProvider<P>,
                storageClass: GoogleStorageClass = .standard, options: ResourceOptions = .init()) {
        resource = Resource(name, attributes: ["name": bucketName.erased, "project": provider.project.erased,
            "location": .literal(R.name), "storage_class": .literal(storageClass.rawValue),
            "uniform_bucket_level_access": .literal(true), "public_access_prevention": .literal("enforced"),
            "force_destroy": .literal(false)], provider: provider.provider, options: options)
    }
    public var name: Value<String> { resource.unsafeAttribute("name") }
    public var url: Value<String> { resource.unsafeAttribute("url") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
