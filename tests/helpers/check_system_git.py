#!/usr/bin/env python3
"""Check the system Git capability used by read-only source inspection."""
from pathlib import Path
import subprocess
import tempfile


def main():
    # Match the product's isolated command environment rather than inheriting
    # a developer's aliases, hooks, credentials, or DEVELOPER_DIR.
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
        "GIT_NO_LAZY_FETCH": "1", "LC_ALL": "C",
    }
    with tempfile.TemporaryDirectory(prefix="harvis-system-git-") as directory:
        root = Path(directory)
        subprocess.run(["/usr/bin/git", "-C", str(root), "init", "--quiet"],
                       env=environment, check=True)
        subprocess.run([
            "/usr/bin/git", "-C", str(root), "-c", "user.name=Harvis Test",
            "-c", "user.email=demo@example.test", "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null",
            "commit", "--quiet", "--allow-empty", "-m", "Synthetic capability probe",
        ], env=environment, check=True)
        result = subprocess.run([
            "/usr/bin/git", "--no-optional-locks", "-C", str(root),
            "rev-parse", "--verify", "--quiet", "--symbolic-full-name", "@{upstream}",
        ], env=environment, capture_output=True)
        if result.returncode != 1 or result.stdout or result.stderr:
            raise SystemExit(
                "System Git lacks quiet missing-upstream behavior; select a supported "
                "Xcode toolchain (Git 2.41+). Source inspection must remain fail-closed. "
                "Probe exit=%d stdoutBytes=%d stderrBytes=%d"
                % (result.returncode, len(result.stdout), len(result.stderr))
            )
        print("System Git quiet missing-upstream capability: OK")


if __name__ == "__main__":
    main()
