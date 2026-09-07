#!/usr/bin/env python3
"""Validate the curated AWS example and compile bindings against a real AWS schema. No AWS API calls."""
import json
import os
import pathlib
import platform
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
env = dict(os.environ, CHECKPOINT_DISABLE="1", NIDO_SWIFT_JOBS="1")
subprocess.run(["swift", "build", "--jobs", "1"], cwd=ROOT, env=env, check=True)
binary = pathlib.Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, env=env, text=True).strip())
with tempfile.TemporaryDirectory(prefix="nido-aws-schema-") as scratch:
    scratch = pathlib.Path(scratch)
    subprocess.run([str(binary / "nido-aws-example"), "--nido-output", str(scratch)], check=True, env=env)
    # Pin the schema used for this compatibility gate; normal application projects use their own lockfile.
    config_file = scratch / "main.tf.json"
    config = json.loads(config_file.read_text())
    config["terraform"]["required_providers"]["aws"]["version"] = "= 6.0.0"
    config_file.write_text(json.dumps(config))
    subprocess.run(["terraform", "init", "-backend=false", "-input=false", "-no-color"], cwd=scratch, env=env, check=True)
    subprocess.run(["terraform", "validate", "-no-color"], cwd=scratch, env=env, check=True)
    schema = subprocess.check_output(["terraform", "providers", "schema", "-json"], cwd=scratch, env=env)
    schema_file, generated = scratch / "schema.json", scratch / "GeneratedAWS.swift"
    schema_file.write_bytes(schema)
    command = [str(binary / "nido"), "provider", "generate", "--schema", str(schema_file), "--prefix", "GeneratedAWS", "--provider-version", "= 6.0.0", "--output", str(generated)]
    for resource in ["aws_vpc", "aws_subnet", "aws_security_group", "aws_ami", "aws_instance", "aws_s3_bucket"]:
        command += ["--type", resource]
    subprocess.run(command, env=env, check=True)
    compiler = ["swiftc", "-typecheck", "-I", str(binary / "Modules"), str(generated)]
    if sys.platform == "darwin":
        compiler += ["-target", f"{platform.machine()}-apple-macosx13.0"]
    subprocess.run(compiler, env=env, check=True)
    print("PASS real AWS 6.0.0 provider validation and generated Swift bindings")
