import XCTest
import Nido
import NidoAWS
import NidoAzure
import NidoGoogleCloud

private enum Subscription: AzureSubscriptionScope {}
private enum Project: GoogleProjectScope {}
private enum Network: NetworkScope {}

final class MultiCloudTests: XCTestCase {
    func testAzureRelationshipsAndReusedNetworkScope() throws {
        let provider = AzureProvider(subscriptionID: "test-subscription", scope: Subscription.self)
        let group = AzureResourceGroup("rg", resourceGroupName: "app", region: JapanEast.self, provider: provider)
        let vnet = AzureVirtualNetwork("vnet", networkName: "vnet", group: group, cidr: try IPv4CIDR("10.0.0.0/16"), scope: Network.self)
        let subnet = AzureSubnet("subnet", subnetName: "private", network: vnet, cidr: try IPv4CIDR("10.0.1.0/24"))
        let nsg = AzureNetworkSecurityGroup("nsg", securityGroupName: "nsg", network: vnet, rules: [
            try .init("https", priority: 100, ports: PortRange(443), source: IPv4CIDR("10.0.0.0/16"), destination: IPv4CIDR("10.0.1.0/24"))
        ])
        let nic = AzureNetworkInterface("nic", interfaceName: "nic", subnet: subnet, securityGroup: nsg)
        let vm = AzureLinuxVirtualMachine("vm", machineName: "vm", interface: nic,
                                         size: AzureVMSize<X86_64>.standardB2s, image: .ubuntu2204,
                                         adminUsername: "nido", sshPublicKey: "PUBLIC-KEY")
        let stack = Stack("Azure") { provider; group; vnet; subnet; nsg; nic; vm }
        let graph = try stack.graph()
        XCTAssertTrue(graph.nodes.first { $0.id == "azurerm_linux_virtual_machine.vm" }!.dependencies.contains("azurerm_network_interface_security_group_association.nic_security"))
        XCTAssertTrue(graph.nodes.first { $0.id == "azurerm_network_interface_security_group_association.nic_security" }!.dependencies.contains("azurerm_network_security_rule.nsg_rule_0"))
        let text = String(decoding: try stack.configuration().encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("disable_password_authentication"))
        XCTAssertTrue(text.contains("${azurerm_subnet.subnet.id}"))
        XCTAssertFalse(try graph.render(.svg).contains("PUBLIC-KEY"))
        let other = AzureVirtualNetwork("other", networkName: "other", group: group, cidr: try IPv4CIDR("10.2.0.0/16"), scope: Network.self)
        let otherNSG = AzureNetworkSecurityGroup("other", securityGroupName: "other", network: other)
        let invalid = AzureNetworkInterface("invalid", interfaceName: "invalid", subnet: subnet, securityGroup: otherNSG)
        XCTAssertThrowsError(try Stack("bad") { provider; group; vnet; subnet; other; otherNSG; invalid }.validate())
        let outside = AzureSubnet("outside", subnetName: "outside", network: vnet, cidr: try IPv4CIDR("192.168.1.0/24"))
        XCTAssertThrowsError(try Stack("outside") { provider; group; vnet; outside }.validate())
    }

    func testGoogleGlobalNetworkAndRegionalInstances() throws {
        let provider = GoogleProvider(project: "test-project", scope: Project.self)
        let network = GoogleNetwork("net", networkName: "net", provider: provider, scope: Network.self)
        let tokyo = GoogleSubnetwork("tokyo", subnetName: "tokyo", network: network, region: AsiaNortheast1.self, cidr: try IPv4CIDR("10.0.0.0/24"))
        let us = GoogleSubnetwork("us", subnetName: "us", network: network, region: USCentral1.self, cidr: try IPv4CIDR("10.1.0.0/24"))
        let firewall = GoogleFirewall("https", firewallName: "https", network: network, targetTag: "app", source: try IPv4CIDR("10.0.0.0/8"), allow: .init(.tcp, ports: try PortRange(443)))
        let instance = GoogleComputeInstance("vm", instanceName: "vm", subnet: tokyo, zone: try GoogleZone<AsiaNortheast1>("asia-northeast1-a"), machineType: GoogleMachineType<X86_64>.e2Small, image: .debian12, firewalls: [firewall])
        let stack = Stack("Google") { provider; network; tokyo; us; firewall; instance }
        let text = String(decoding: try stack.configuration().encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("asia-northeast1")); XCTAssertTrue(text.contains("us-central1"))
        XCTAssertTrue(text.contains("${google_compute_subnetwork.tokyo.self_link}"))
        XCTAssertFalse(text.contains("access_config")) // Private interface is the default.
        XCTAssertTrue(try stack.graph().nodes.first { $0.id == "google_compute_instance.vm" }!.dependencies.contains("google_compute_firewall.https"))
        XCTAssertThrowsError(try GoogleZone<AsiaNortheast1>("us-central1-a"))
        let other = GoogleNetwork("other", networkName: "other", provider: provider, scope: Network.self)
        let wrong = GoogleFirewall("wrong", firewallName: "wrong", network: other, targetTag: "wrong", source: try IPv4CIDR("10.0.0.0/8"), allow: .init(.tcp, ports: try PortRange(443)))
        let invalid = GoogleComputeInstance("bad", instanceName: "bad", subnet: tokyo, zone: try GoogleZone<AsiaNortheast1>("asia-northeast1-a"), machineType: GoogleMachineType<X86_64>.e2Small, image: .debian12, firewalls: [wrong])
        XCTAssertThrowsError(try Stack("bad") { provider; network; tokyo; other; wrong; invalid }.validate())
    }

    func testThreeProvidersAndCloudSpecificDiagrams() throws {
        let aws = AWSProvider<APNortheast1>()
        let azure = AzureProvider(subscriptionID: "subscription", scope: Subscription.self)
        let group = AzureResourceGroup("rg", resourceGroupName: "rg", region: JapanEast.self, provider: azure)
        let google = GoogleProvider(project: "project", scope: Project.self)
        let a = S3Bucket("a", bucket: "secret-aws-bucket", provider: aws)
        let b = AzureStorageAccount("b", accountName: "secretazurestorage", group: group)
        let c = GoogleStorageBucket("c", bucketName: "secret-google-bucket", region: AsiaNortheast1.self, provider: google)
        let stack = Stack("MultiCloud") { aws; azure; google; group; a; b; c }
        let configuration = try JSONSerialization.jsonObject(with: stack.configuration().encoded()) as! [String: Any]
        let terraform = configuration["terraform"] as! [String: Any]
        XCTAssertEqual(Set((terraform["required_providers"] as! [String: Any]).keys), ["aws", "azurerm", "google"])
        for format in [DiagramFormat.svg, .dot, .mermaid] {
            let output = try stack.graph().render(format)
            for cloud in ["AWS Cloud", "Microsoft Azure", "Google Cloud"] { XCTAssertTrue(output.contains(cloud)) }
            XCTAssertFalse(output.contains("secret"))
        }
        let svg = try stack.graph().render(.svg)
        XCTAssertTrue(svg.contains("#0078d4")); XCTAssertTrue(svg.contains("#188038"))
    }
}
