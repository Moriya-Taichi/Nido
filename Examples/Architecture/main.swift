import Nido

// A conceptual architecture, not a deployable AWS stack. Attach resource addresses when
// using these annotations with managed resources; Nido checks that they exist.
var groups: [DiagramGroup] = [.init("aws", label: "AWS Cloud", kind: .cloud, row: 1)]
var services: [DiagramService] = [
    .init("clients", label: "Users / Internet", icon: .client),
    .init("routing", label: "Latency-based routing", icon: .cdn, parent: "aws"),
]
var links: [DiagramConnection] = [.init("clients", "routing", label: "HTTPS")]
for (region, label) in [("tokyo", "Asia Pacific · Tokyo"), ("oregon", "US West · Oregon")] {
    groups += [
        .init(region, label: label, kind: .region, parent: "aws", row: 1),
        .init("\(region)-vpc", label: "Application VPC", kind: .vpc, parent: region, row: 1),
    ]
    services.append(.init("\(region)-lb", label: "Load balancer", icon: .loadBalancer, parent: region))
    links.append(.init("routing", "\(region)-lb"))
    for zone in ["a", "b"] {
        let id = "\(region)-\(zone)"
        groups.append(.init(id, label: "Availability Zone \(zone.uppercased())", kind: .availabilityZone, parent: "\(region)-vpc"))
        services += [
            .init("\(id)-app", label: "Application servers", icon: .compute, parent: id),
            .init("\(id)-db", label: "Database", icon: .database, parent: id, row: 1),
        ]
        links += [.init("\(region)-lb", "\(id)-app"), .init("\(id)-app", "\(id)-db", label: "SQL")]
    }
    links.append(.init("\(region)-a-db", "\(region)-b-db", kind: .replication))
}
links.append(.init("oregon-b-db", "tokyo-a-db", label: "Cross-region sync", kind: .replication))
try Stack("Multi-region web service · conceptual", architecture: Architecture(
    groups: groups, services: services, connections: links
)) {}.export()
