import Foundation
import Nido
import NidoSchema
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct ExitStatus: Error { let code: Int32 }

private func withWorkingDirectoryLock<T>(_ directory: URL, create: Bool, _ body: () throws -> T) throws -> T {
    if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    guard FileManager.default.fileExists(atPath: directory.path) else {
        throw NidoError("Working directory does not exist. Run nido synth or nido init first.")
    }
    let descriptor = open(directory.appendingPathComponent(".nido.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw NidoError("Cannot open Nido working directory lock") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw NidoError("Nido working directory is busy: \(directory.path)") }
    defer { _ = flock(descriptor, LOCK_UN) }
    // Keep this inode: removing a lock file can let another process lock a different inode.
    return try body()
}

private func run(_ executable: String, _ arguments: [String], directory: URL? = nil) throws {
    let process = Process()
    if executable.contains("/") {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    }
    process.currentDirectoryURL = directory
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    let code = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    if code != 0 { throw ExitStatus(code: code) }
}

private let help = """
Nido — type-safe infrastructure in Swift

Usage: nido [options] <command> [arguments]

Options (before the command):
  --package PATH       Swift package containing the infrastructure (default: .)
  --product NAME       Infrastructure executable (default: Infrastructure)
  --directory PATH     Terraform working directory (default: <package>/.nido)
  --engine PATH        terraform or tofu executable (default: terraform)
  --skip-synth         Use existing configuration, for example when applying a saved plan

Commands:
  new PATH [--local-package PATH]   Create an infrastructure Swift package
  synth                            Compile Swift, validate, and emit .tf.json and graph JSON
  diagram [--view architecture|dependencies] [--format mermaid|dot|svg] [--output PATH] [--from GRAPH.json]
  provider generate --schema PATH --provider-version CONSTRAINT
      [--provider SOURCE] [--prefix NAME] [--type NAME ...] [--output PATH]
  init | validate | plan | apply | destroy | import | refresh
  output | show | state | workspace | providers | force-unlock | graph | console
  exec COMMAND [ARGS]              Pass any other command to the selected Terraform engine

Engine arguments are passed unchanged. Relative engine paths (plans, var-files, module
sources, backend paths) resolve inside the Terraform working directory. Apply and destroy
retain the engine's confirmation prompts. Nido never adds -auto-approve or disables locking.

Examples:
  nido new MyInfrastructure
  nido --package MyInfrastructure init
  nido --package MyInfrastructure plan -out=review.tfplan
  nido --package MyInfrastructure --skip-synth apply review.tfplan
  nido --package MyInfrastructure diagram --format svg --output architecture.svg
"""

private func take(_ args: inout [String], _ label: String) throws -> String {
    guard !args.isEmpty else { throw NidoError("Missing value for \(label)") }
    return args.removeFirst()
}

private func swiftString(_ text: String) -> String {
    "\"" + text.unicodeScalars.map { scalar -> String in
        switch scalar.value {
        case 34: return "\\\""
        case 92: return "\\\\"
        case 0...31, 127: return "\\u{\(String(scalar.value, radix: 16))}"
        default: return String(scalar)
        }
    }.joined() + "\""
}

private func newProject(_ args: inout [String]) throws {
    let target = URL(fileURLWithPath: try take(&args, "new"), isDirectory: true).standardizedFileURL
    var localPackage: String?
    if !args.isEmpty {
        guard args.removeFirst() == "--local-package" else { throw NidoError("Expected --local-package PATH") }
        localPackage = URL(fileURLWithPath: try take(&args, "--local-package"), isDirectory: true).standardizedFileURL.path
    }
    guard args.isEmpty else { throw NidoError("Unexpected new arguments: \(args)") }
    if FileManager.default.fileExists(atPath: target.path),
       !(try FileManager.default.contentsOfDirectory(atPath: target.path)).isEmpty {
        throw NidoError("Project directory is not empty: \(target.path)")
    }
    if let localPackage, !FileManager.default.fileExists(atPath: localPackage + "/Package.swift") {
        throw NidoError("Local Nido package has no Package.swift: \(localPackage)")
    }
    let dependency = localPackage.map { ".package(name: \"Nido\", path: \(swiftString($0)))" }
        ?? ".package(url: \"https://github.com/Moriya-Taichi/Nido.git\", branch: \"main\")"
    let package = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "Infrastructure",
        platforms: [.macOS(.v13)],
        dependencies: [\(dependency)],
        targets: [.executableTarget(name: "Infrastructure", dependencies: [.product(name: "Nido", package: "Nido")])]
    )
    """
    let source = """
    import Nido

    let message = Variable<String>("message", default: "Hello from Nido")
    let greeting = TerraformData("greeting", input: message.value)
    try Stack("Infrastructure") {
        message
        greeting
        Output("message", value: greeting.output)
    }.export()
    """
    let sourceDir = target.appendingPathComponent("Sources/Infrastructure", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try AtomicFile.write(Data((package + "\n").utf8), to: target.appendingPathComponent("Package.swift"))
    try AtomicFile.write(Data((source + "\n").utf8), to: sourceDir.appendingPathComponent("main.swift"))
    try AtomicFile.write(Data(".build/\n.swiftpm/\n.terraform/\n*.tfstate\n*.tfstate.*\n*.tfplan\n.nido/.nido.lock\n.nido/main.tf.json\n.nido/nido.graph.json\n".utf8),
                         to: target.appendingPathComponent(".gitignore"))
    print("Created \(target.path). Run nido init, then nido plan in that directory.")
}

private func generateProvider(_ args: inout [String]) throws {
    guard try take(&args, "provider") == "generate" else { throw NidoError("Expected provider generate") }
    var schema: String?, source: String?, prefix: String?, version: String?, output: String?
    var includeTypes = Set<String>()
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--schema": schema = try take(&args, arg)
        case "--provider": source = try take(&args, arg)
        case "--prefix": prefix = try take(&args, arg)
        case "--provider-version": version = try take(&args, arg)
        case "--output": output = try take(&args, arg)
        case "--type": includeTypes.insert(try take(&args, arg))
        default: throw NidoError("Unknown provider generate argument: \(arg)")
        }
    }
    guard let schema, let version, !version.isEmpty else { throw NidoError("--schema and --provider-version are required") }
    let generated = try SchemaGenerator.generate(from: Data(contentsOf: URL(fileURLWithPath: schema)),
                                                  provider: source, prefix: prefix, version: version, includeTypes: includeTypes)
    if let output { try AtomicFile.write(Data(generated.utf8), to: URL(fileURLWithPath: output)) }
    else { print(generated, terminator: "") }
}

private func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var package = cwd, product = "Infrastructure", requestedDirectory: URL?
    var engine = ProcessInfo.processInfo.environment["NIDO_TERRAFORM"] ?? "terraform"
    var skipSynthesis = false
    while let arg = args.first, arg.hasPrefix("--") {
        args.removeFirst()
        switch arg {
        case "--help": print(help); return
        case "--version": print("Nido 0.1.0-dev"); return
        case "--package": package = URL(fileURLWithPath: try take(&args, arg), isDirectory: true).standardizedFileURL
        case "--product": product = try take(&args, arg)
        case "--directory": requestedDirectory = URL(fileURLWithPath: try take(&args, arg), isDirectory: true).standardizedFileURL
        case "--engine": engine = try take(&args, arg)
        case "--skip-synth": skipSynthesis = true
        default: throw NidoError("Unknown Nido option \(arg). Engine options go after the command.")
        }
    }
    guard !args.isEmpty else { print(help); return }
    let command = args.removeFirst()
    if command == "help" || command == "-h" { print(help); return }
    if command == "new" { try newProject(&args); return }
    if command == "provider" { try generateProvider(&args); return }
    let directory = requestedDirectory ?? package.appendingPathComponent(".nido", isDirectory: true)
    if engine.contains("/") { engine = URL(fileURLWithPath: engine).standardizedFileURL.path }
    func synthesize() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("nido-synth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var buildOptions: [String] = []
        if let jobs = ProcessInfo.processInfo.environment["NIDO_SWIFT_JOBS"] {
            guard let count = Int(jobs), count > 0 else { throw NidoError("NIDO_SWIFT_JOBS must be a positive integer") }
            buildOptions = ["--jobs", jobs]
        }
        try run("swift", ["run", "--package-path", package.path, "--quiet"] + buildOptions + [product, "--nido-output", staging.path])
        guard FileManager.default.fileExists(atPath: staging.appendingPathComponent("main.tf.json").path),
              FileManager.default.fileExists(atPath: staging.appendingPathComponent("nido.graph.json").path) else {
            throw NidoError("Infrastructure executable must call try stack.export()")
        }
        let config = try Data(contentsOf: staging.appendingPathComponent("main.tf.json"))
        let graphData = try Data(contentsOf: staging.appendingPathComponent("nido.graph.json"))
        _ = try JSONDecoder().decode(JSONValue.self, from: config)
        _ = try JSONDecoder().decode(InfrastructureGraph.self, from: graphData).render(.mermaid)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicFile.write(graphData, to: directory.appendingPathComponent("nido.graph.json"))
        try AtomicFile.write(config, to: directory.appendingPathComponent("main.tf.json"))
    }
    if command == "synth" {
        guard args.isEmpty else { throw NidoError("synth does not accept engine arguments") }
        try withWorkingDirectoryLock(directory, create: true) { try synthesize() }
        print(directory.path); return
    }
    if command == "diagram" {
        var view = DiagramView.architecture
        var format = DiagramFormat.mermaid, output: String?, input: String?
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--view":
                guard let v = DiagramView(rawValue: try take(&args, arg)) else { throw NidoError("Expected architecture or dependencies") }
                view = v
            case "--format":
                guard let f = DiagramFormat(rawValue: try take(&args, arg)) else { throw NidoError("Expected mermaid, dot, or svg") }
                format = f
            case "--output": output = try take(&args, arg)
            case "--from": input = try take(&args, arg)
            default: throw NidoError("Unknown diagram argument \(arg)")
            }
        }
        func render() throws -> String {
            if input == nil && !skipSynthesis { try synthesize() }
            let graphURL = input.map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("nido.graph.json")
            return try JSONDecoder().decode(InfrastructureGraph.self, from: Data(contentsOf: graphURL)).render(format, view: view)
        }
        let rendered = try input == nil ? withWorkingDirectoryLock(directory, create: !skipSynthesis) { try render() } : render()
        if let output { try AtomicFile.write(Data(rendered.utf8), to: URL(fileURLWithPath: output)) }
        else { print(rendered, terminator: "") }
        return
    }
    let synthesisCommands: Set<String> = ["init", "validate", "plan", "apply", "destroy", "import", "refresh"]
    let readCommands: Set<String> = ["output", "show", "state", "workspace", "providers", "force-unlock", "graph", "console"]
    var engineArgs: [String]
    if command == "exec" {
        guard !args.isEmpty else { throw NidoError("exec requires a Terraform command") }
        engineArgs = args.first == "--" ? Array(args.dropFirst()) : args
        guard !engineArgs.isEmpty else { throw NidoError("exec requires a Terraform command") }
    } else {
        guard synthesisCommands.contains(command) || readCommands.contains(command) else { throw NidoError("Unknown command \(command). Use nido --help.") }
        engineArgs = [command] + args
    }
    let needsSynthesis = synthesisCommands.contains(command) && !skipSynthesis
    try withWorkingDirectoryLock(directory, create: needsSynthesis) {
        if needsSynthesis { try synthesize() }
        try run(engine, engineArgs, directory: directory)
    }
}

do { try main() }
catch let status as ExitStatus { exit(status.code) }
catch {
    FileHandle.standardError.write(Data("nido: \(error)\n".utf8))
    exit(1)
}
