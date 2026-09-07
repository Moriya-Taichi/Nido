import Nido

let greeting = Variable<String>("greeting", default: "Hello from Swift")
let first = TerraformData("greeting", input: greeting.value)
let second = TerraformData("consumer", input: first.output)

let stack = Stack("Nido example") {
    greeting
    first
    second
    Output("message", value: second.output)
}
try stack.export()
