import Nido
import NidoAWS

enum AppNetwork: NetworkScope {}
let tokyo = AWSProvider<APNortheast1>()
let vpc = VPC("app", cidr: try IPv4CIDR("10.0.0.0/16"), provider: tokyo, scope: AppNetwork.self)
let subnet = Subnet("app", vpc: vpc, cidr: try IPv4CIDR("10.0.1.0/24"))
let security = SecurityGroup("app", vpc: vpc, description: "Private application",
                            ingress: [.tcp(try PortRange(443), from: try IPv4CIDR("10.0.0.0/16"))])
let image = AMI("linux", provider: tokyo, architecture: ARM64.self,
                owners: .literal(["amazon"]), namePattern: "al2023-ami-2023.*-arm64")
let server = EC2Instance("app", image: image, instanceType: .t4gMicro,
                         subnet: subnet, securityGroups: [security])

try Stack("Private application in Tokyo") {
    tokyo
    vpc
    subnet
    security
    image
    server
    Output("instance_id", value: server.id)
}.export()
