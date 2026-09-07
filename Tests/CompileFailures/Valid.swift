import Nido
import NidoAWS

enum App: NetworkScope {}
let provider = AWSProvider<APNortheast1>()
let vpc = VPC("app", cidr: try IPv4CIDR("10.0.0.0/16"), provider: provider, scope: App.self)
let subnet = Subnet("app", vpc: vpc, cidr: try IPv4CIDR("10.0.1.0/24"))
let group = SecurityGroup("app", vpc: vpc, description: "app")
let image = AMI("linux", provider: provider, architecture: ARM64.self, owners: .literal(["amazon"]), namePattern: "linux-*")
let server = EC2Instance("app", image: image, instanceType: .t4gMicro, subnet: subnet, securityGroups: [group])
let stack = Stack("valid") { provider; vpc; subnet; group; image; server }
