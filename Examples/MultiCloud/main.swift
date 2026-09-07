import Nido
import NidoAWS
import NidoAzure
import NidoGoogleCloud

enum AzureProduction: AzureSubscriptionScope {}
enum GoogleProduction: GoogleProjectScope {}
enum AWSNetwork: NetworkScope {}
enum AzureNetwork: NetworkScope {}
enum GCPNetwork: NetworkScope {}

let subscription = Variable<String>("azure_subscription_id")
let project = Variable<String>("google_project_id")
let sshKey = Variable<String>("azure_ssh_public_key", description: "SSH public key for the Azure VM")
let azureStorageName = Variable<String>("azure_storage_name")
let googleBucketName = Variable<String>("google_bucket_name")
let awsBucketName = Variable<String>("aws_bucket_name")

let aws = AWSProvider<APNortheast1>()
let vpc = VPC("aws_app", cidr: try IPv4CIDR("10.0.0.0/16"), provider: aws, scope: AWSNetwork.self)
let subnet = Subnet("aws_app", vpc: vpc, cidr: try IPv4CIDR("10.0.1.0/24"))
let sg = SecurityGroup("aws_app", vpc: vpc, description: "Private application")
let ami = AMI("aws_linux", provider: aws, architecture: ARM64.self, owners: .literal(["amazon"]), namePattern: "al2023-ami-2023.*-arm64")
let ec2 = EC2Instance("aws_app", image: ami, instanceType: .t4gMicro, subnet: subnet, securityGroups: [sg])
let s3 = S3Bucket("aws_objects", bucket: awsBucketName.value, provider: aws)

let azure = AzureProvider(subscriptionID: subscription.value, scope: AzureProduction.self)
let rg = AzureResourceGroup("azure_app", resourceGroupName: "nido-app", region: JapanEast.self, provider: azure)
let vnet = AzureVirtualNetwork("azure_app", networkName: "nido-vnet", group: rg, cidr: try IPv4CIDR("10.1.0.0/16"), scope: AzureNetwork.self)
let azureSubnet = AzureSubnet("azure_app", subnetName: "private", network: vnet, cidr: try IPv4CIDR("10.1.1.0/24"))
let nsg = AzureNetworkSecurityGroup("azure_app", securityGroupName: "nido-nsg", network: vnet, rules: [
    try AzureSecurityRule("https", priority: 100, ports: PortRange(443), source: IPv4CIDR("10.1.0.0/16"), destination: IPv4CIDR("10.1.1.0/24")),
])
let nic = AzureNetworkInterface("azure_app", interfaceName: "nido-nic", subnet: azureSubnet, securityGroup: nsg)
let vm = AzureLinuxVirtualMachine("azure_app", machineName: "nido-app", interface: nic,
                                 size: AzureVMSize<X86_64>.standardB2s, image: AzureLinuxImage<X86_64>.ubuntu2204,
                                 adminUsername: "nido", sshPublicKey: sshKey.value)
let storage = AzureStorageAccount("azure_objects", accountName: azureStorageName.value, group: rg)
let container = AzureBlobContainer("azure_objects", containerName: "objects", account: storage)

let google = GoogleProvider(project: project.value, scope: GoogleProduction.self)
let network = GoogleNetwork("google_app", networkName: "nido-vpc", provider: google, scope: GCPNetwork.self)
let googleSubnet = GoogleSubnetwork("google_app", subnetName: "nido-private", network: network, region: AsiaNortheast1.self, cidr: try IPv4CIDR("10.2.1.0/24"))
let firewall = GoogleFirewall("google_app", firewallName: "nido-https", network: network, targetTag: "nido-app",
                              source: try IPv4CIDR("10.2.0.0/16"), allow: .init(.tcp, ports: try PortRange(443)))
let gce = GoogleComputeInstance("google_app", instanceName: "nido-app", subnet: googleSubnet, zone: try GoogleZone<AsiaNortheast1>("asia-northeast1-a"),
                                 machineType: GoogleMachineType<X86_64>.e2Small, image: GoogleImage<X86_64>.debian12, firewalls: [firewall])
let gcs = GoogleStorageBucket("google_objects", bucketName: googleBucketName.value, region: AsiaNortheast1.self, provider: google)

// Boundaries and services correspond to the definitions above. No cross-cloud connectivity is declared.
let architecture = Architecture(groups: [
    .init("aws", label: "AWS Cloud", kind: .cloud, cloud: .aws),
    .init("aws-region", label: APNortheast1.name, kind: .region, parent: "aws"),
    .init("aws-vpc", label: "Application VPC", kind: .vpc, parent: "aws-region"),
    .init("azure", label: "Microsoft Azure", kind: .cloud, cloud: .azure),
    .init("azure-region", label: JapanEast.name, kind: .region, parent: "azure"),
    .init("azure-vnet", label: "Application VNet", kind: .vpc, parent: "azure-region"),
    .init("google", label: "Google Cloud", kind: .cloud, cloud: .googleCloud),
    .init("google-region", label: AsiaNortheast1.name, kind: .region, parent: "google"),
    .init("google-vpc", label: "Application subnet", kind: .subnet, parent: "google-region"),
], services: [
    .init("ec2", label: "Amazon EC2", icon: .compute, parent: "aws-vpc", resource: ec2.dependency.address),
    .init("s3", label: "Amazon S3", icon: .bucket, parent: "aws-region", resource: s3.dependency.address, row: 1),
    .init("vm", label: "Azure Virtual Machine", icon: .compute, parent: "azure-vnet", resource: vm.dependency.address),
    .init("blob", label: "Azure Blob Storage", icon: .bucket, parent: "azure-region", resource: container.dependency.address, row: 1),
    .init("gce", label: "Compute Engine", icon: .compute, parent: "google-vpc", resource: gce.dependency.address),
    .init("gcs", label: "Cloud Storage", icon: .bucket, parent: "google-region", resource: gcs.dependency.address, row: 1),
])
try Stack("Nido · AWS / Azure / Google Cloud", architecture: architecture) {
    subscription; project; sshKey; azureStorageName; googleBucketName; awsBucketName
    aws; vpc; subnet; sg; ami; ec2; s3
    azure; rg; vnet; azureSubnet; nsg; nic; vm; storage; container
    google; network; googleSubnet; firewall; gce; gcs
    Output("aws_instance_id", value: ec2.id)
    Output("azure_vm_id", value: vm.id)
    Output("google_instance_id", value: gce.id)
}.export()
