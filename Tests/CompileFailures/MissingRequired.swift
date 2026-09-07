import Nido
import NidoAWS
enum App: NetworkScope {}
let provider = AWSProvider<APNortheast1>()
let vpc = VPC("app", provider: provider, scope: App.self)
