import Nido
import NidoAWS
let provider = AWSProvider<APNortheast1>()
let bucket = S3Bucket("bucket", bucket: "example", provider: provider)
let subnet = Subnet("app", vpc: bucket, cidr: try IPv4CIDR("10.0.1.0/24"))
