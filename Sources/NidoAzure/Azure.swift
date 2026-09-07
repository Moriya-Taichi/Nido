import Nido

public protocol AzureSubscriptionScope: Sendable {}
public protocol AzureRegion: Sendable { static var name: String { get } }
public enum JapanEast: AzureRegion { public static let name = "japaneast" }
public enum EastUS: AzureRegion { public static let name = "eastus" }
public enum WestEurope: AzureRegion { public static let name = "westeurope" }

/// Credentials come from the AzureRM provider's standard environment/CLI/OIDC mechanisms.
public struct AzureProvider<S: AzureSubscriptionScope>: Component {
    public let provider: Provider
    public init(subscriptionID: Value<String>, scope: S.Type, alias: String? = nil, version: String = "~> 4.0") {
        provider = Provider(.init("azurerm", source: "hashicorp/azurerm", version: version), alias: alias,
                            configuration: ["subscription_id": subscriptionID.erased, "features": .array([.object([:])])])
    }
    public var blocks: [Block] { provider.blocks }
}
public enum AzureResourceGroupKind: ResourceKind { public static let terraformType = "azurerm_resource_group" }
public struct AzureResourceGroup<R: AzureRegion, S: AzureSubscriptionScope>: Component {
    public let resource: Resource<AzureResourceGroupKind>
    public let provider: AzureProvider<S>
    public init(_ name: String, resourceGroupName: Value<String>, region: R.Type, provider: AzureProvider<S>,
                options: ResourceOptions = .init()) {
        self.provider = provider
        resource = Resource(name, attributes: ["name": resourceGroupName.erased, "location": .literal(R.name)],
                            provider: provider.provider, options: options)
    }
    public var name: Value<String> { resource.unsafeAttribute("name") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
public enum AzureVNetID<R: AzureRegion, S: AzureSubscriptionScope, N: NetworkScope>: Sendable {}
public enum AzureSubnetID<R: AzureRegion, S: AzureSubscriptionScope, N: NetworkScope>: Sendable {}
public enum AzureNICID<R: AzureRegion, S: AzureSubscriptionScope, N: NetworkScope>: Sendable {}
public enum AzureVNetKind: ResourceKind { public static let terraformType = "azurerm_virtual_network" }
public struct AzureVirtualNetwork<R: AzureRegion, S: AzureSubscriptionScope, N: NetworkScope>: Component {
    public let resource: Resource<AzureVNetKind>
    public let group: AzureResourceGroup<R, S>
    public let cidr: IPv4CIDR
    public init(_ name: String, networkName: Value<String>, group: AzureResourceGroup<R, S>, cidr: IPv4CIDR,
                scope: N.Type, options: ResourceOptions = .init()) {
        self.group = group; self.cidr = cidr
        resource = Resource(name, attributes: ["name": networkName.erased, "resource_group_name": group.name.erased,
                            "location": .literal(R.name), "address_space": .literal([cidr.description])],
                            provider: group.provider.provider, options: options)
    }
    public var id: Value<AzureVNetID<R, S, N>> { resource.unsafeAttribute("id") }
    public var name: Value<String> { resource.unsafeAttribute("name") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
public enum AzureSubnetKind: ResourceKind { public static let terraformType = "azurerm_subnet" }
public struct AzureSubnet<R: AzureRegion, S: AzureSubscriptionScope, N: NetworkScope>: Component {
    public let resource: Resource<AzureSubnetKind>
    public let network: AzureVirtualNetwork<R, S, N>
    public init(_ name: String, subnetName: Value<String>, network: AzureVirtualNetwork<R, S, N>, cidr: IPv4CIDR,
                options: ResourceOptions = .init()) {
        self.network = network
        var issues: [String] = []
        if !network.cidr.contains(cidr) { issues.append("Azure subnet CIDR must be contained in its virtual network") }
        if cidr.prefix > 29 { issues.append("Azure IPv4 subnet must be /29 or larger") }
        resource = Resource(name, attributes: ["name": subnetName.erased, "resource_group_name": network.group.name.erased,
                            "virtual_network_name": network.name.erased, "address_prefixes": .literal([cidr.description])],
                            provider: network.group.provider.provider, options: options, issues: issues)
    }
    public var id: Value<AzureSubnetID<R, S, N>> { resource.unsafeAttribute("id") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
public struct AzureSecurityRule: Sendable {
    public enum Direction: String, Sendable { case inbound = "Inbound", outbound = "Outbound" }
    public enum Access: String, Sendable { case allow = "Allow", deny = "Deny" }
    public enum Transport: String, Sendable { case tcp = "Tcp", udp = "Udp" }
    let name: String, priority: Int, direction: Direction, access: Access, transport: Transport
    let ports: PortRange, source: IPv4CIDR, destination: IPv4CIDR
    public init(_ name: String, priority: Int, direction: Direction = .inbound, access: Access = .allow,
                transport: Transport = .tcp, ports: PortRange, source: IPv4CIDR, destination: IPv4CIDR) throws {
        guard (100...4096).contains(priority) else { throw NidoError("Azure NSG priority must be 100...4096") }
        self.name = name; self.priority = priority; self.direction = direction; self.access = access
        self.transport = transport; self.ports = ports; self.source = source; self.destination = destination
    }
}
public enum AzureNSGKind: ResourceKind { public static let terraformType = "azurerm_network_security_group" }
public enum AzureNSGRuleKind: ResourceKind { public static let terraformType = "azurerm_network_security_rule" }
public struct AzureNetworkSecurityGroup<R: AzureRegion, S: AzureSubscriptionScope, N: NetworkScope>: Component {
    public let resource: Resource<AzureNSGKind>
    public let network: AzureVirtualNetwork<R, S, N>
    public let blocks: [Block]
    public init(_ name: String, securityGroupName: Value<String>, network: AzureVirtualNetwork<R, S, N>,
                rules: [AzureSecurityRule] = [], options: ResourceOptions = .init()) {
        self.network = network
        let group = network.group
        let priorities = rules.map { "\($0.direction.rawValue):\($0.priority)" }
        resource = Resource(name, attributes: ["name": securityGroupName.erased, "resource_group_name": group.name.erased,
                            "location": .literal(R.name)], provider: group.provider.provider, options: options,
                            issues: Set(priorities).count == priorities.count && Set(rules.map(\.name)).count == rules.count ? [] : ["Duplicate Azure NSG rule name or priority within direction"])
        let nsgName: Value<String> = resource.unsafeAttribute("name")
        blocks = resource.blocks + rules.enumerated().flatMap { index, rule in
            Resource<AzureNSGRuleKind>("\(name)_rule_\(index)", attributes: [
                "name": .literal(rule.name), "resource_group_name": group.name.erased,
                "network_security_group_name": nsgName.erased, "priority": .literal(rule.priority),
                "direction": .literal(rule.direction.rawValue), "access": .literal(rule.access.rawValue),
                "protocol": .literal(rule.transport.rawValue), "source_port_range": .literal("*"),
                "destination_port_range": .literal(rule.ports.lower == rule.ports.upper ? "\(rule.ports.lower)" : "\(rule.ports.lower)-\(rule.ports.upper)"),
                "source_address_prefix": .literal(rule.source.description), "destination_address_prefix": .literal(rule.destination.description),
            ], provider: group.provider.provider).blocks
        }
    }
    public var dependency: Dependency { resource.dependency }
}
public enum AzureNICKind: ResourceKind { public static let terraformType = "azurerm_network_interface" }
public enum AzureNICNSGKind: ResourceKind { public static let terraformType = "azurerm_network_interface_security_group_association" }
public struct AzureNetworkInterface<R: AzureRegion, S: AzureSubscriptionScope, N: NetworkScope>: Component {
    public let resource: Resource<AzureNICKind>
    public let subnet: AzureSubnet<R, S, N>
    public let blocks: [Block]
    public init(_ name: String, interfaceName: Value<String>, subnet: AzureSubnet<R, S, N>,
                securityGroup: AzureNetworkSecurityGroup<R, S, N>, options: ResourceOptions = .init()) {
        self.subnet = subnet
        let group = subnet.network.group
        resource = Resource(name, attributes: ["name": interfaceName.erased, "resource_group_name": group.name.erased,
                            "location": .literal(R.name), "ip_configuration": .array([.object([
                                "name": .literal("private"), "subnet_id": subnet.id.erased,
                                "private_ip_address_allocation": .literal("Dynamic")])])],
                            provider: group.provider.provider, options: options,
                            issues: subnet.network.dependency == securityGroup.network.dependency ? [] : ["Azure NIC subnet and NSG must use the same virtual network"])
        let nicID: Value<AzureNICID<R, S, N>> = resource.unsafeAttribute("id")
        let nsgID: Value<String> = securityGroup.resource.unsafeAttribute("id")
        blocks = resource.blocks + Resource<AzureNICNSGKind>("\(name)_security", attributes: [
            "network_interface_id": nicID.erased, "network_security_group_id": nsgID.erased,
        ], provider: group.provider.provider, options: .init(dependsOn: securityGroup.blocks.map { Dependency($0.address) })).blocks
    }
    public var id: Value<AzureNICID<R, S, N>> { resource.unsafeAttribute("id") }
    public var dependency: Dependency { resource.dependency }
}
public struct AzureVMSize<A: CPUArchitecture>: Sendable {
    public let name: String
    private init(_ name: String) { self.name = name }
    public static func unchecked(_ name: String) -> Self { Self(name) }
}
extension AzureVMSize where A == X86_64 { public static var standardB2s: Self { Self("Standard_B2s") } }
extension AzureVMSize where A == ARM64 { public static var standardD2psV5: Self { Self("Standard_D2ps_v5") } }
public struct AzureLinuxImage<A: CPUArchitecture>: Sendable {
    let publisher: String, offer: String, sku: String, version: String
    private init(publisher: String, offer: String, sku: String, version: String) {
        self.publisher = publisher; self.offer = offer; self.sku = sku; self.version = version
    }
    /// The caller must verify the custom image's CPU architecture.
    public static func unchecked(publisher: String, offer: String, sku: String, version: String = "latest") -> Self {
        Self(publisher: publisher, offer: offer, sku: sku, version: version)
    }
}
extension AzureLinuxImage where A == X86_64 {
    public static var ubuntu2204: Self { Self(publisher: "Canonical", offer: "ubuntu-22_04-lts", sku: "server", version: "latest") }
}
extension AzureLinuxImage where A == ARM64 {
    public static var ubuntu2204: Self { Self(publisher: "Canonical", offer: "ubuntu-22_04-lts", sku: "server-arm64", version: "latest") }
}
public enum AzureVMKind: ResourceKind { public static let terraformType = "azurerm_linux_virtual_machine" }
public struct AzureLinuxVirtualMachine<R: AzureRegion, S: AzureSubscriptionScope, N: NetworkScope, A: CPUArchitecture>: Component {
    public let resource: Resource<AzureVMKind>
    public init(_ name: String, machineName: Value<String>, interface: AzureNetworkInterface<R, S, N>,
                size: AzureVMSize<A>, image: AzureLinuxImage<A>, adminUsername: Value<String>, sshPublicKey: Value<String>,
                options: ResourceOptions = .init()) {
        let group = interface.subnet.network.group
        var options = options
        options.dependsOn += interface.blocks.map { Dependency($0.address) }
        resource = Resource(name, attributes: ["name": machineName.erased, "resource_group_name": group.name.erased,
            "location": .literal(R.name), "size": .literal(size.name), "admin_username": adminUsername.erased,
            "disable_password_authentication": .literal(true), "network_interface_ids": Value<[AzureNICID<R, S, N>]>.list([interface.id]).erased,
            "admin_ssh_key": .array([.object(["username": adminUsername.erased, "public_key": sshPublicKey.erased])]),
            "os_disk": .array([.object(["caching": .literal("ReadWrite"), "storage_account_type": .literal("Standard_LRS")])]),
            "source_image_reference": .array([.object(["publisher": .literal(image.publisher), "offer": .literal(image.offer),
                                                       "sku": .literal(image.sku), "version": .literal(image.version)])]),
        ], provider: group.provider.provider, options: options)
    }
    public var id: Value<String> { resource.unsafeAttribute("id") }
    public var privateIP: Value<String> { resource.unsafeAttribute("private_ip_address") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
public enum AzureStorageKind: ResourceKind { public static let terraformType = "azurerm_storage_account" }
public enum AzureStorageReplication: String, Sendable { case lrs = "LRS", zrs = "ZRS", grs = "GRS", raGRS = "RAGRS", gzrs = "GZRS", raGZRS = "RAGZRS" }
public struct AzureStorageAccount<R: AzureRegion, S: AzureSubscriptionScope>: Component {
    public let resource: Resource<AzureStorageKind>
    public let group: AzureResourceGroup<R, S>
    public init(_ name: String, accountName: Value<String>, group: AzureResourceGroup<R, S>,
                replication: AzureStorageReplication = .lrs, options: ResourceOptions = .init()) {
        self.group = group
        resource = Resource(name, attributes: ["name": accountName.erased, "resource_group_name": group.name.erased,
            "location": .literal(R.name), "account_tier": .literal("Standard"), "account_kind": .literal("StorageV2"),
            "account_replication_type": .literal(replication.rawValue), "min_tls_version": .literal("TLS1_2"),
            "allow_nested_items_to_be_public": .literal(false)], provider: group.provider.provider, options: options)
    }
    public var name: Value<String> { resource.unsafeAttribute("name") }
    public var id: Value<String> { resource.unsafeAttribute("id") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
public enum AzureContainerKind: ResourceKind { public static let terraformType = "azurerm_storage_container" }
public struct AzureBlobContainer<R: AzureRegion, S: AzureSubscriptionScope>: Component {
    public let resource: Resource<AzureContainerKind>
    public init(_ name: String, containerName: Value<String>, account: AzureStorageAccount<R, S>, options: ResourceOptions = .init()) {
        resource = Resource(name, attributes: ["name": containerName.erased, "storage_account_name": account.name.erased,
                                             "container_access_type": .literal("private")], provider: account.group.provider.provider, options: options)
    }
    public var id: Value<String> { resource.unsafeAttribute("id") }
    public var blocks: [Block] { resource.blocks }
    public var dependency: Dependency { resource.dependency }
}
