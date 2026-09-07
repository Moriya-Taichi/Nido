#!/usr/bin/env python3
"""Exercise real Terraform/OpenTofu with isolated local state and its built-in provider only."""
import json
import fcntl
import os
import pathlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENGINE = os.environ.get("NIDO_TEST_ENGINE", "terraform")
assert shutil.which(ENGINE), f"Install {ENGINE} or set NIDO_TEST_ENGINE"
subprocess.run(["swift", "build", "--jobs", "1"], cwd=ROOT, check=True)
bin_dir = pathlib.Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
NIDO = str(bin_dir / "nido")
env = dict(os.environ, NIDO_SWIFT_JOBS="1", CHECKPOINT_DISABLE="1", TF_IN_AUTOMATION="1")


def run(args, cwd, expected=0, extra_env=None):
    result = subprocess.run(args, cwd=cwd, env=dict(env, **(extra_env or {})), text=True, capture_output=True)
    assert result.returncode == expected, f"{' '.join(map(str, args))}\n{result.stdout}\n{result.stderr}"
    return result.stdout


with tempfile.TemporaryDirectory(prefix="nido-e2e-") as scratch:
    scratch = pathlib.Path(scratch)
    project = scratch / "project with spaces"
    run([NIDO, "new", str(project), "--local-package", str(ROOT)], scratch)
    cli = [NIDO, "--engine", ENGINE]
    run(cli + ["init", "-input=false"], project)
    with (project / ".nido/.nido.lock").open("r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run(cli + ["--skip-synth", "plan", "-input=false"], cwd=project, env=env, text=True, capture_output=True)
        assert result.returncode != 0 and "busy" in result.stderr, result.stderr
    run(cli + ["validate", "-no-color"], project)
    run(cli + ["plan", "-input=false", "-no-color", "-detailed-exitcode", "-out=review.tfplan"], project, expected=2)
    run(cli + ["--skip-synth", "apply", "-input=false", "-no-color", "review.tfplan"], project)
    assert run(cli + ["output", "-raw", "message"], project) == "Hello from Nido"
    run(cli + ["plan", "-input=false", "-no-color", "-detailed-exitcode"], project)
    run(cli + ["plan", "-input=false", "-no-color", "-detailed-exitcode", "-out=update.tfplan", "-var=message=updated"], project, expected=2)
    run(cli + ["--skip-synth", "apply", "-input=false", "update.tfplan"], project)
    assert run(cli + ["output", "-raw", "message"], project) == "updated"
    assert "terraform_data.greeting" in run(cli + ["state", "list"], project)

    # Workspace state is isolated by the execution engine.
    run(cli + ["workspace", "new", "other"], project)
    run(cli + ["plan", "-input=false", "-detailed-exitcode"], project, expected=2)
    run(cli + ["workspace", "select", "default"], project)
    assert run(cli + ["output", "-raw", "message"], project) == "updated"
    run(cli + ["workspace", "delete", "other"], project)

    for format, extension in [("mermaid", "mmd"), ("dot", "dot"), ("svg", "svg")]:
        path = scratch / ("architecture." + extension)
        run(cli + ["diagram", "--format", format, "--output", str(path)], project)
        diagram = path.read_text()
        assert "greeting" in diagram, "The declared resource must appear in the diagram"
        assert diagram.startswith({"mermaid": "flowchart", "dot": "digraph", "svg": "<svg"}[format])
        assert "Hello from Nido" not in diagram
        if format == "svg":
            ET.parse(path)

    # A compile failure, or a successful program that forgot export(), must never apply stale files.
    main = project / "Sources/Infrastructure/main.swift"
    original = main.read_text()
    old_config = (project / ".nido/main.tf.json").read_bytes()
    for broken in ['import Nido\nlet x: String = false\n', 'import Nido\nprint("forgot export")\n']:
        main.write_text(broken)
        result = subprocess.run(cli + ["plan", "-input=false"], cwd=project, env=env, text=True, capture_output=True)
        assert result.returncode != 0
        assert (project / ".nido/main.tf.json").read_bytes() == old_config
    main.write_text(original)

    # Local tfvars paths are resolved inside .nido, exactly like Terraform's working directory.
    (project / ".nido/input.tfvars.json").write_text(json.dumps({"message": "updated"}))
    run(cli + ["plan", "-input=false", "-detailed-exitcode", "-var-file=input.tfvars.json"], project)
    run(cli + ["destroy", "-input=false", "-auto-approve", "-no-color"], project)
    assert run(cli + ["state", "list"], project).strip() == ""
    print(f"PASS {ENGINE}: init, validate, saved plan, apply, update, no-op, state, workspaces, diagrams, failed synthesis, destroy")
