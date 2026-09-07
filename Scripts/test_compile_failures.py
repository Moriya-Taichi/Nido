#!/usr/bin/env python3
"""Test positive and negative programs with the real Swift compiler."""
import pathlib
import platform
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "--jobs", "1"], cwd=ROOT, check=True)
bin_dir = pathlib.Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
command = ["swiftc", "-typecheck", "-I", str(bin_dir / "Modules")]
if sys.platform == "darwin":
    command += ["-target", f"{platform.machine()}-apple-macosx13.0"]
fixtures = ROOT / "Tests" / "CompileFailures"
valid = (fixtures / "Valid.swift").read_text()


def check(path, succeeds, expected=""):
    result = subprocess.run(command + [str(path)], text=True, capture_output=True)
    if succeeds:
        assert result.returncode == 0, result.stderr
    else:
        assert result.returncode != 0, f"Unexpectedly compiled: {path.name}"
        assert "no such module" not in result.stderr, result.stderr
        expected = (expected,) if isinstance(expected, str) else expected
        assert any(diagnostic in result.stderr for diagnostic in expected), result.stderr
    print(f"PASS {path.name}")


check(fixtures / "Valid.swift", True)
for filename, diagnostic in {
    "WrongValue.swift": "cannot convert",
    "MissingRequired.swift": "missing argument",
    "WrongResourceKind.swift": "cannot convert",
    "EmptyRequiredCollection.swift": "missing argument",
}.items():
    check(fixtures / filename, False, diagnostic)

# Derive each invalid program from the successful fixture to isolate the constraint.
cases = {
    "WrongArchitecture.swift": (valid.replace("instanceType: .t4gMicro", "instanceType: InstanceType<X86_64>.t3Micro"), ("cannot convert", "conflicting arguments")),
    "WrongRegion.swift": (valid.replace('AMI("linux", provider: provider,', 'AMI("linux", provider: AWSProvider<USWest2>(alias: "west"),'), ("cannot convert", "conflicting arguments")),
    "WrongNetwork.swift": (valid.replace('let group = SecurityGroup("app", vpc: vpc,', '''enum Other: NetworkScope {}
let other = VPC("other", cidr: try IPv4CIDR("10.1.0.0/16"), provider: provider, scope: Other.self)
let group = SecurityGroup("app", vpc: other,'''), "cannot convert"),
}
with tempfile.TemporaryDirectory(prefix="nido-compile-") as temp:
    for name, (source, diagnostic) in cases.items():
        path = pathlib.Path(temp) / name
        path.write_text(source)
        check(path, False, diagnostic)
