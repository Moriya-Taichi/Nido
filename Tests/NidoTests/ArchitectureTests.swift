import XCTest
@testable import Nido

final class ArchitectureTests: XCTestCase {
    func testNestedSceneRoundTripAndTrafficCycles() throws {
        let resource = TerraformData("app", input: Value<String>.literal("secret-value"))
        let scene = Architecture(groups: [
            .init("cloud", label: "AWS Cloud", kind: .cloud),
            .init("az", label: "AZ A", kind: .availabilityZone, parent: "cloud")
        ], services: [
            .init("client", label: "Client", icon: .client),
            .init("app", label: "App <&>", icon: .compute, parent: "az", resource: resource.dependency.address)
        ], connections: [.init("client", "app"), .init("app", "client", label: "sync", kind: .replication)])
        let graph = try Stack("Architecture", architecture: scene) { resource }.graph()
        let decoded = try JSONDecoder().decode(InfrastructureGraph.self, from: JSONEncoder().encode(graph))
        XCTAssertEqual(graph, decoded)
        let svg = try decoded.render(.svg)
        XCTAssertTrue(svg.contains("App &lt;&amp;&gt;"))
        XCTAssertTrue(svg.contains("stroke-dasharray"))
        XCTAssertTrue(svg.contains("marker-start"))
        XCTAssertFalse(svg.contains("secret-value"))
        XCTAssertTrue(try graph.render(.mermaid).contains("subgraph"))
        XCTAssertTrue(try graph.render(.dot).contains("cluster_"))
        XCTAssertFalse(try graph.render(.svg, view: .dependencies).contains("AWS Cloud"))
        XCTAssertEqual(try Stack("x") { resource }.configuration(), try Stack("x", architecture: scene) { resource }.configuration())
    }

    func testInvalidAnnotations() throws {
        let scenes: [Architecture] = [
            .init(groups: [.init("x", label: "X", parent: "x")], services: []),
            .init(groups: [.init("x", label: "X", parent: "y"), .init("y", label: "Y", parent: "x")], services: []),
            .init(services: [.init("x", label: "X", parent: "missing")]),
            .init(services: [.init("x", label: "X", resource: "missing")]),
            .init(services: [.init("x", label: "X"), .init("x", label: "duplicate")]),
            .init(services: [], connections: [.init("x", "y")]),
        ]
        for scene in scenes { XCTAssertThrowsError(try Stack("invalid", architecture: scene) {}.graph()) }
    }

    func testLegacyGraphAndDefaultView() throws {
        let legacy = Data(#"{"name":"legacy","nodes":[{"id":"aws_instance.app","kind":"resource","name":"app","type":"aws_instance","dependencies":[]},{"id":"var.secret","kind":"variable","name":"secret","type":"","dependencies":[]}]}"#.utf8)
        let graph = try JSONDecoder().decode(InfrastructureGraph.self, from: legacy)
        XCTAssertTrue(try graph.render(.svg).contains("AWS Cloud"))
        XCTAssertFalse(try graph.render(.svg).contains("var.secret"))
        XCTAssertTrue(try graph.render(.mermaid, view: .dependencies).contains("var.secret"))
    }
}
