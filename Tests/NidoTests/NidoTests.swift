import Foundation
import XCTest
@testable import Nido
import NidoAWS
import NidoSchema

private enum TestResource: ResourceKind { static let terraformType = "test_resource" }
private enum NetworkA: NetworkScope {}

final class NidoTests: XCTestCase {
    func testNonFiniteNumbersFailValidationWithoutTrappingDuringFieldAccess() throws {
        let value: Value<String> = Value<Double>.literal(.nan).unsafeField("invalid")
        XCTAssertThrowsError(try Stack("invalid") { Output("value", value: value) }.configuration())
    }
    func decode(_ stack: Stack) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: stack.configuration().encoded()) as? [String: Any])
    }

    func testLiteralTemplatesAreEscapedButReferencesRemainExpressions() throws {
        let input = Variable<String>("input", default: "${literal}")
        let data = TerraformData("literal", input: Value<[String: String]>.map([
            "template": .literal("${untrusted} %{ if true }"), "reference": input.value,
        ]))
        let json = try decode(Stack("test") { input; data })
        let vars = try XCTUnwrap(json["variable"] as? [String: [String: Any]])
        XCTAssertEqual(vars["input"]?["default"] as? String, "${literal}")
        let resources = try XCTUnwrap(json["resource"] as? [String: [String: [String: Any]]])
        let values = try XCTUnwrap(resources["terraform_data"]?["literal"]?["input"] as? [String: String])
        XCTAssertEqual(values["template"], "$${untrusted} %%{ if true }")
        XCTAssertEqual(values["reference"], "${var.input}")
        XCTAssertEqual(try Stack("test") { input; data }.graph().nodes.first { $0.id == "terraform_data.literal" }?.dependencies, ["var.input"])
    }

    func testDependenciesSurviveNestedObjectsAndCollections() throws {
        let one = TerraformData("one", input: Value<String>.literal("one"))
        let two = Resource<TestResource>("two", attributes: ["nested": .array([.object(["ref": one.output.erased])])])
        let graph = try Stack("deps") { one; two }.graph()
        XCTAssertEqual(graph.nodes.first { $0.id == "test_resource.two" }?.dependencies, ["terraform_data.one"])
    }

    func testMissingDuplicateAndCyclicDeclarationsFailBeforeEmission() throws {
        let resource = TerraformData("one", input: Value<String>.literal("one"))
        XCTAssertThrowsError(try Stack("duplicate") { resource; resource }.configuration())
        XCTAssertThrowsError(try Stack("missing") { Output("out", value: resource.output) }.configuration())
        let a = Resource<TestResource>("a", attributes: [:], options: .init(dependsOn: [.init("test_resource.b")]))
        let b = Resource<TestResource>("b", attributes: [:], options: .init(dependsOn: [.init("test_resource.a")]))
        XCTAssertThrowsError(try Stack("cycle") { a; b }.configuration()) { error in
            XCTAssertTrue(String(describing: error).contains("Dependency cycle"))
        }
        let invalid = TerraformData("bad.name", input: Value<Int>.literal(1))
        XCTAssertThrowsError(try Stack("invalid") { invalid }.configuration())
    }

    func testProviderAliasesAndLifecycleUseLiteralJSONMappings() throws {
        let p = Provider(.init("test", source: "example/test", version: "~> 1.0"), alias: "west")
        let a = Resource<TestResource>("a", attributes: [:], provider: p)
        let b = Resource<TestResource>("b", attributes: [:], provider: p,
            options: .init(dependsOn: [a.dependency], lifecycle: .init(createBeforeDestroy: true, preventDestroy: true, ignoreChanges: .all)))
        let json = try decode(Stack("test", backend: Backend("local", configuration: ["path": .string("state-${literal}.json")])) { p; a; b })
        let resources = try XCTUnwrap(json["resource"] as? [String: [String: [String: Any]]])
        let body = try XCTUnwrap(resources["test_resource"]?["b"])
        XCTAssertEqual(body["provider"] as? String, "test.west")
        XCTAssertEqual(body["depends_on"] as? [String], ["test_resource.a"])
        XCTAssertEqual((body["lifecycle"] as? [String: Any])?["ignore_changes"] as? String, "all")
        XCTAssertTrue(String(data: try Stack("backend", backend: Backend("local", configuration: ["path": .string("${literal}")])) {}.configuration().encoded(), encoding: .utf8)!.contains("${literal}"))
    }

    func testProviderConflictsAreRejected() throws {
        let a = Provider(.init("test", source: "example/test", version: "~> 1.0"))
        let b = Provider(.init("test", source: "example/test", version: "~> 2.0"), alias: "second")
        XCTAssertThrowsError(try Stack("test") { a; b }.configuration())
    }

    func testSensitiveOutputsPropagateAndDiagramsOmitValues() throws {
        let secret = Variable<String>("password", default: "DO-NOT-RENDER", sensitive: true)
        let data = TerraformData("secret", input: secret.value)
        let stack = Stack("sensitive") { secret; data; Output("secret", value: data.output) }
        let json = try decode(stack)
        XCTAssertEqual((json["output"] as? [String: [String: Any]])?["secret"]?["sensitive"] as? Bool, true)
        for format in [DiagramFormat.mermaid, .dot, .svg] {
            XCTAssertFalse(try stack.graph().render(format).contains("DO-NOT-RENDER"))
        }
    }

    func testSynthesisIsDeterministicAndPreservesStateAndLocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = TerraformData("a", input: Value<Int>.literal(1))
        let b = TerraformData("b", input: a.output)
        let forward = Stack("stable") { a; b }, reverse = Stack("stable") { b; a }
        XCTAssertEqual(try forward.configuration(), try reverse.configuration())
        XCTAssertEqual(try forward.graph().render(.svg), try reverse.graph().render(.svg))
        try forward.synthesize(to: dir)
        let state = dir.appendingPathComponent("terraform.tfstate"), lock = dir.appendingPathComponent(".terraform.lock.hcl")
        try Data("state".utf8).write(to: state); try Data("lock".utf8).write(to: lock)
        try reverse.synthesize(to: dir)
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8), "state")
        XCTAssertEqual(try String(contentsOf: lock, encoding: .utf8), "lock")
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("main.tf.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testBuilderSupportsCompositionConditionsAndLoops() throws {
        let enabled = true
        let part = Components {
            if enabled { TerraformData("enabled", input: Value<Bool>.literal(true)) }
            for i in 0..<3 { TerraformData("item_\(i)", input: Value<Int>.literal(i)) }
        }
        XCTAssertEqual(try Stack("composition") { part }.graph().nodes.count, 4)
    }

    func testAWSArchitectureFilterAndVpcValidation() throws {
        let provider = AWSProvider<APNortheast1>()
        let vpc = VPC("app", cidr: try IPv4CIDR("10.0.0.0/16"), provider: provider, scope: NetworkA.self)
        let subnet = Subnet("app", vpc: vpc, cidr: try IPv4CIDR("10.0.1.0/24"))
        let image = AMI("linux", provider: provider, architecture: ARM64.self, owners: .literal(["amazon"]), namePattern: "linux-*")
        let instance = EC2Instance("app", image: image, instanceType: .t4gMicro, subnet: subnet)
        let json = try decode(Stack("aws") { provider; vpc; subnet; image; instance })
        let data = try XCTUnwrap(json["data"] as? [String: [String: [String: Any]]])
        let filters = try XCTUnwrap(data["aws_ami"]?["linux"]?["filter"] as? [[String: Any]])
        XCTAssertEqual(filters.first { $0["name"] as? String == "architecture" }?["values"] as? [String], ["arm64"])
        let outside = Subnet("outside", vpc: vpc, cidr: try IPv4CIDR("192.168.1.0/24"))
        XCTAssertThrowsError(try Stack("outside") { provider; vpc; outside }.configuration())
        // A reused phantom marker must not allow distinct actual VPCs to be mixed.
        let otherVpc = VPC("other", cidr: try IPv4CIDR("10.1.0.0/16"), provider: provider, scope: NetworkA.self)
        let group = SecurityGroup("other", vpc: otherVpc, description: "test")
        let wrong = EC2Instance("wrong", image: image, instanceType: .t4gMicro, subnet: subnet, securityGroups: [group])
        XCTAssertThrowsError(try Stack("wrong") { provider; vpc; otherVpc; subnet; group; image; wrong }.configuration())
    }

    func testCIDRsAndPortsRejectInvalidValues() throws {
        for cidr in ["10.0.0.1/24", "256.0.0.0/16", "10.0.0.0/33", "abc", "10..0.0/16"] {
            XCTAssertThrowsError(try IPv4CIDR(cidr))
        }
        XCTAssertTrue(try IPv4CIDR("0.0.0.0/0").contains(IPv4CIDR("192.168.1.0/24")))
        XCTAssertThrowsError(try PortRange(65536))
    }

    func testGraphEscapingAndUntrustedGraphs() throws {
        let graph = try Stack("<script>\"&\n") { TerraformData("ok", input: Value<Int>.literal(1)) }.graph()
        let svg = try graph.render(.svg)
        XCTAssertFalse(svg.contains("<script>"))
        XCTAssertTrue(svg.contains("&lt;script&gt;"))
        let cycle = InfrastructureGraph(name: "cycle", nodes: [GraphNode(id: "a", kind: "resource", name: "a", type: "x", dependencies: ["a"])])
        XCTAssertThrowsError(try cycle.render(.svg))
        let missing = InfrastructureGraph(name: "missing", nodes: [GraphNode(id: "a", kind: "resource", name: "a", type: "x", dependencies: ["b"])])
        XCTAssertThrowsError(try missing.render(.mermaid))
    }

    func testImportMoveAndModuleMappings() throws {
        let resource = TerraformData("new", input: Value<String>.literal("ok"))
        let module = TerraformModule("external", source: "../modules/example", inputs: ["message": resource.output.erased])
        let stack = Stack("migrate", imports: [.init(id: "remote-id", to: resource.dependency)],
                          moves: [.init(from: "terraform_data.old", to: resource.dependency)]) { resource; module }
        let json = try decode(stack)
        XCTAssertEqual((json["import"] as? [[String: String]])?.first?["to"], "terraform_data.new")
        XCTAssertEqual((json["moved"] as? [[String: String]])?.first?["from"], "terraform_data.old")
        XCTAssertEqual((json["module"] as? [String: [String: String]])?["external"]?["message"], "${terraform_data.new.output}")
    }

    func testGeneratorRejectsUnknownVersionsAndTypes() throws {
        XCTAssertThrowsError(try SchemaGenerator.generate(from: Data(#"{"format_version":"2.0","provider_schemas":{}}"#.utf8), version: "1.0"))
        let schema = #"{"format_version":"1.0","provider_schemas":{"example/test":{"resource_schemas":{"test_thing":{"block":{"attributes":{"value":{"required":true,"type":"unknown"}}}}}}}}"#
        XCTAssertThrowsError(try SchemaGenerator.generate(from: Data(schema.utf8), version: "1.0"))
    }
}
