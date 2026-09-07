import Nido
let boolean = Variable<Bool>("enabled")
let resource = TerraformData<String>("message", input: boolean.value)
