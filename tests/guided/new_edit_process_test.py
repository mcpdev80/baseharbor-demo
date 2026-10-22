#!/usr/bin/env python3
"""Real CLI PTY regressions without a daemon; not native runtime evidence.

Usage: python3 tests/guided/new_edit_process_test.py /absolute/path/to/baha
The binary is supplied explicitly so a successful run is bound to the actual
candidate under review. No runtime command is invoked in this regression.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    binary = str(Path(sys.argv[1]).resolve(strict=True))
    with tempfile.TemporaryDirectory(prefix="baseharbor-new-edit-process-") as directory:
        root = Path(directory)
        project = root / "project"
        project.mkdir()
        (project / "compose.yaml").write_text("services:\n  api:\n    image: alpine:3.22\n    command: [sleep, '300']\n")
        os.environ.update({"DEMO_ROOT": str(project), "BAHA": binary,
            "ARTIFACT_DIR": str(root / "artifacts"), "BASEHARBOR_TARGET": "new-edit-process",
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_DATA_HOME": str(root / "data"),
            "BASEHARBOR_STATE_DIR": str(root / "state"), "BASEHARBOR_LOGS_ENABLED": "false",
            "TERM": "xterm-256color"})
        subprocess.run([binary, "target", "create", "new-edit-process", "--provider", "docker",
            "--access", "local-docker", "--reference", "local", "--scope", "default", "--default"],
            cwd=project, check=True, timeout=30, stdout=subprocess.DEVNULL)
        subprocess.run([binary, "init", "--quick", "--json"], cwd=project, check=True,
                       timeout=30, stdout=subprocess.DEVNULL)
        import new_edit
        parent = project / "children"
        parent.mkdir()
        new_edit.new_application(parent, "new-cancel", decision="cancel", native=False)
        new_edit.new_application(parent, "new-no", decision="no", native=False)
        new_edit.new_application(parent, "new-eof", decision="eof", native=False)
        new_edit.edit_application(project, "cancel", native=False)
        new_edit.footprint_parity(project)
        print(json.dumps({"journey": "real-cli-pty-new-no-cancel-eof-edit-cancel", "result": "success",
                          "source_and_state_unchanged": True, "native_runtime_qualified": False}))


if __name__ == "__main__":
    main()
