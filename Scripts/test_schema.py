#!/usr/bin/env python3
"""Compile generated provider bindings and ensure invalid client code fails."""
import pathlib
import platform
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "--jobs", "1"], cwd=ROOT, check=True)
bin_dir = pathlib.Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
with tempfile.TemporaryDirectory(prefix="nido-schema-") as temp:
    temp = pathlib.Path(temp)
    generated, client = temp / "Generated.swift", temp / "main.swift"
    subprocess.run([str(bin_dir / "nido"), "provider", "generate", "--schema", str(ROOT / "Tests/Fixtures/provider-schema.json"),
                    "--prefix", "Fixture", "--provider-version", "~> 1.0", "--output", str(generated)], check=True)
    valid = '''import Nido
let provider = FixtureProvider(region: "test")
let network = FixtureServerNetworkBlock(cidr: "10.0.0.0/16")
let rule = FixtureServerRuleBlock(port: .literal(443.0))
let settings = FixtureServerSettingsObject(enabled: true, threshold: .literal(0.5))
let pair = FixtureServerPairTuple(element0: "a", element1: .literal(1.0))
let server = FixtureServer("app", provider: provider, name: "app", pair: pair.value, settings: settings.value, network: network, rule: NonEmpty(rule))
let image = FixtureDataImage("image", provider: provider, name: "linux")
let host: Value<String> = server.connection.host
let output: Value<String> = server.id
'''
    command = ["swiftc", "-typecheck", "-I", str(bin_dir / "Modules"), str(generated), str(client)]
    if sys.platform == "darwin":
        command += ["-target", f"{platform.machine()}-apple-macosx13.0"]
    cases = {
        "valid": valid,
        "missing_required": valid.replace('name: "app", ', ""),
        "wrong_scalar": valid.replace('name: "app", ', "name: true, "),
        "computed_input": valid.replace('name: "app", ', 'name: "app", id: "forged", '),
        "missing_nested": valid.replace("network: network, ", ""),
        "empty_required_collection": valid.replace("NonEmpty(rule)", "[]"),
        "wrong_nested_field": valid.replace("threshold: .literal(0.5)", 'threshold: "wrong"'),
        "wrong_output_type": valid.replace("let host: Value<String>", "let host: Value<Bool>"),
    }
    for name, source in cases.items():
        client.write_text(source)
        result = subprocess.run(command, text=True, capture_output=True)
        assert (result.returncode == 0) == (name == "valid"), result.stderr or name
        assert "no such module" not in result.stderr, result.stderr
        print(f"PASS generated {name}")

    # Also execute the generated bindings, so cardinality, nesting and dependencies are checked.
    package = temp / "Package.swift"
    package.write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SchemaTest", platforms: [.macOS(.v13)], dependencies: [.package(path: "{ROOT}")], targets: [.executableTarget(name: "SchemaTest", dependencies: [.product(name: "Nido", package: "Nido")], path: ".", exclude: ["Package.swift"])])
''')
    client.write_text(valid + '\ntry Stack("schema") { provider; server; image; Output("host", value: host) }.export()\n')
    output = temp / "output"
    result = subprocess.run(["swift", "run", "--jobs", "1", "--package-path", str(temp), "SchemaTest", "--nido-output", str(output)], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    import json
    config = json.loads((output / "main.tf.json").read_text())
    resource = config["resource"]["fixture_server"]["app"]
    assert resource["network"] == [{"cidr": "10.0.0.0/16"}]
    assert resource["pair"] == ["a", 1]
    assert resource["settings"] == {"enabled": True, "threshold": 0.5}
    assert config["output"]["host"]["value"] == "${(fixture_server.app.connection).host}"
    client.write_text((valid + '\ntry Stack("schema") { provider; server; image }.export()\n').replace("NonEmpty(rule)", "NonEmpty(rule, rest: [rule, rule, rule])"))
    result = subprocess.run(["swift", "run", "--jobs", "1", "--package-path", str(temp), "SchemaTest", "--nido-output", str(output)], text=True, capture_output=True)
    assert result.returncode != 0 and "at most 3" in result.stderr, result.stderr
    print("PASS generated runtime nesting and cardinality")
