#!/usr/bin/env python3
"""Offline interface checks. Never launch a real reviewer, build, or rebase."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PLUGIN = Path(__file__).resolve().parents[1]


class CompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="k8s-compatibility-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo with spaces"
        self.repo.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        # Ignore user signing/hooks and environment-injected Git directories.
        for key in list(self.env):
            if key.startswith("GIT_"):
                del self.env[key]
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.run_cmd("git", "init", "-q", "-b", "main", check=True)
        self.run_cmd("git", "config", "user.name", "Compatibility Test", check=True)
        self.run_cmd("git", "config", "user.email", "test@example.invalid", check=True)
        (self.repo / "main.go").write_text("package main\n")
        self.commit("base")
        self.base = self.git_sha()
        self.run_cmd("git", "checkout", "-qb", "rebase", check=True)
        (self.repo / "main.go").write_text("package main\n// fix $HOME $(false)\n")
        self.commit("fix")
        self.claude_called = self.root / "claude-called"
        self.env["REVIEW_CAPTURE"] = str(self.claude_called)
        self.stub("claude", 'cat > "$REVIEW_CAPTURE"\nprintf "%s\\n" "${TEST_VERDICT:-APPROVE: fixture}"\n')

    def run_cmd(self, *args, check=False, **kwargs):
        return subprocess.run(args, cwd=self.repo, env=self.env, text=True,
                              capture_output=True, check=check, **kwargs)

    def commit(self, message):
        self.run_cmd("git", "add", ".", check=True)
        self.run_cmd("git", "commit", "-qm", message, check=True)

    def git_sha(self):
        return self.run_cmd("git", "rev-parse", "HEAD", check=True).stdout.strip()

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)

    def review(self, scope="fix", *args):
        name = "k8s-rebase-review.sh" if scope == "fix" else "k8s-rebase-pr-review.sh"
        return self.run_cmd("bash", str(PLUGIN / "scripts" / name), *args)

    def test_prompt_scopes_and_no_claude(self):
        fix = self.review("fix", "--print-prompt", "HEAD", "undefined: oldAPI")
        pr = self.review("pr", "--print-prompt", self.base, "1.36.0")
        for result in (fix, pr):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("$HOME $(false)", result.stdout)
        self.assertIn("undefined: oldAPI", fix.stdout)
        self.assertIn("ALL fields", fix.stdout)
        self.assertIn("COMMIT COMPLETENESS", pr.stdout)
        self.assertIn("1.36.0", pr.stdout)
        self.assertIn("fix", pr.stdout)
        self.assertIn(f"REVIEW COMMIT: {self.git_sha()}", fix.stdout)
        self.assertIn(f"REVIEW SCOPE: {self.base}..{self.git_sha()}", pr.stdout)
        self.assertNotIn("COMMIT COMPLETENESS", fix.stdout)
        self.assertFalse(self.claude_called.exists())

    def test_invalid_references_and_missing_arguments(self):
        for scope in ("fix", "pr"):
            context = "context" if scope == "fix" else "1.36.0"
            for args in (("--print-prompt",), ("--print-prompt", "missing", context),
                         ("--print-prompt", "--help", context),
                         ("--print-prompt", "HEAD:main.go", context)):
                with self.subTest(scope=scope, args=args):
                    result = self.review(scope, *args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("APPROVE:", result.stdout)
        self.assertFalse(self.claude_called.exists())

    def test_evidence_command_failures(self):
        real_git = shutil.which("git")
        for scope, command in (("fix", "show"), ("pr", "diff"), ("pr", "log")):
            with self.subTest(scope=scope, command=command):
                self.stub("git", f'for arg in "$@"; do [[ "$arg" == {command} ]] && exit 17; done\nexec "{real_git}" "$@"\n')
                ref = "HEAD" if scope == "fix" else self.base
                context = "context" if scope == "fix" else "1.36.0"
                result = self.review(scope, "--print-prompt", ref, context)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("APPROVE:", result.stdout)
        self.assertFalse(self.claude_called.exists())

    def test_render_failure(self):
        self.stub("envsubst", "exit 19\n")
        result = self.review("fix", "--print-prompt", "HEAD", "context")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("APPROVE:", result.stdout)
        self.assertFalse(self.claude_called.exists())

    def test_failed_ancestry_check(self):
        real_git = shutil.which("git")
        self.stub("git", f'for arg in "$@"; do [[ "$arg" == --is-ancestor ]] && exit 17; done\nexec "{real_git}" "$@"\n')
        for scope, ref, context in (("fix", "HEAD", "context"), ("pr", self.base, "1.36.0")):
            result = self.review(scope, "--print-prompt", ref, context)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("APPROVE:", result.stdout)
        self.assertFalse(self.claude_called.exists())

    def test_failed_truncation_does_not_prepare_prompt(self):
        self.stub("head", "exit 19\n")
        for scope, ref, context in (("fix", "HEAD", "context"), ("pr", self.base, "1.36.0")):
            result = self.review(scope, "--print-prompt", ref, context)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("APPROVE:", result.stdout)
        self.assertFalse(self.claude_called.exists())

    def test_pre_pr_evidence_uses_snapshot_if_head_moves(self):
        reviewed = self.git_sha()
        real_git = shutil.which("git")
        self.stub("git", f'''if [[ "$1" == diff ]]; then
  "{real_git}" commit --allow-empty -qm "later commit" || exit 1
fi
exec "{real_git}" "$@"
''')
        result = self.review("pr", "--print-prompt", self.base, "1.36.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(reviewed, self.git_sha())
        self.assertIn(f"REVIEW SCOPE: {self.base}..{reviewed}", result.stdout)
        self.assertNotIn("later commit", result.stdout)
        self.assertFalse(self.claude_called.exists())

    def test_missing_template(self):
        copied = self.root / "script copy"
        copied.mkdir()
        shutil.copy(PLUGIN / "scripts/k8s-rebase-review.sh", copied)
        result = self.run_cmd("bash", str(copied / "k8s-rebase-review.sh"),
                              "--print-prompt", "HEAD", "context")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("APPROVE:", result.stdout)

    def test_empty_filtered_diff_is_valid(self):
        self.run_cmd("git", "checkout", "-qb", "empty-filter", self.base, check=True)
        (self.repo / "docs.md").write_text("documentation only\n")
        self.commit("docs only")
        fix = self.review("fix", "--print-prompt", "HEAD", "context")
        pr = self.review("pr", "--print-prompt", "HEAD", "1.36.0")
        self.assertEqual(fix.returncode, 0, fix.stderr)
        self.assertEqual(pr.returncode, 0, pr.stderr)
        self.assertFalse(self.claude_called.exists())

    def test_truncation_disclosed(self):
        (self.repo / "large.go").write_text("// large\n" * 2400)
        (self.repo / "large.md").write_text("documentation\n" * 20000)
        self.commit("large diff")
        for scope, ref in (("fix", "HEAD"), ("pr", self.base)):
            context = "context" if scope == "fix" else "1.36.0"
            result = self.review(scope, "--print-prompt", ref, context)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("truncated", result.stdout)

    def test_claude_default_verdicts(self):
        for verdict, expected in (("APPROVE: fixture", 0), ("REJECT: fixture", 1),
                                  ("malformed", 0)):
            with self.subTest(verdict=verdict):
                self.env["TEST_VERDICT"] = verdict
                result = self.review("fix", "HEAD", "context")
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertTrue(self.claude_called.exists())
        result = self.review("pr", self.base, "1.36.0")
        self.assertEqual(result.returncode, 0)
        self.assertIn("COMMIT COMPLETENESS", self.claude_called.read_text())

    def activate(self, step=3):
        state = self.repo / ".rebase-tmp"
        state.mkdir(exist_ok=True)
        (state / ".session-active").touch()
        (state / "state.json").write_text(json.dumps({"current_step": step, "version": "1.36.0"}))

    def hook(self, name, tool_input, tool_name="Bash", **extra):
        payload = {"cwd": str(self.repo), "tool_name": tool_name,
                   "tool_input": tool_input, **extra}
        result = self.run_cmd("bash", str(PLUGIN / "hooks" / name), input=json.dumps(payload))
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def test_vendor_payloads(self):
        self.activate()
        for header in ("Add File", "Update File", "Delete File", "Move to"):
            for path in ("vendor/a.go", "module/vendor/a.go", "\tvendor/a.go", "ven\tdor/a.go",
                         str(self.repo / "vendor/a.go")):
                with self.subTest(header=header, path=path):
                    patch = f"*** Begin Patch\n*** Update File: safe.go\n*** {header}: {path}\n*** End Patch\n"
                    result = self.hook("block-vendor-edit.sh", {"command": patch}, "apply_patch")
                    self.assertEqual(result.get("decision"), "block")
        self.assertEqual(self.hook("block-vendor-edit.sh", {"file_path": "vendor/a.go"}, "Edit").get("decision"), "block")
        self.assertFalse(self.hook("block-vendor-edit.sh", {"command": "*** Update File: main.go\n+// vendor/a.go"}, "apply_patch"))
        self.assertFalse(self.hook("block-vendor-edit.sh", {"command": "*** Add File:   vendor/a.go\n+package fixture"}, "apply_patch"))
        (self.repo / ".rebase-tmp/.session-active").unlink()
        self.assertFalse(self.hook("block-vendor-edit.sh", {"command": "*** Delete File: vendor/a.go"}, "apply_patch"))

    def test_existing_shell_hooks_and_guards(self):
        self.activate()
        cases = (("block-push.sh", "git push origin HEAD"),
                 ("block-push.sh", "gh pr create --title test"),
                 ("block-module-ops.sh", "go mod tidy"),
                 ("block-prior-step-rm.sh", "rm .rebase-tmp/gates/step2-build-vet.report"))
        for name, command in cases:
            self.assertEqual(self.hook(name, {"command": command}).get("decision"), "block")
        # Codex hook cwd stays at the session root during module-local work.
        self.assertEqual(self.hook("block-module-ops.sh", {"command": "cd module && go mod tidy"}).get("decision"), "block")
        (self.repo / ".rebase-tmp/.session-active").unlink()
        for name, command in cases:
            self.assertFalse(self.hook(name, {"command": command}))

    def test_stop_hook(self):
        self.assertFalse(self.hook("stop-hook.sh", {}))
        self.activate()
        self.assertEqual(self.hook("stop-hook.sh", {}).get("decision"), "block")
        self.assertFalse(self.hook("stop-hook.sh", {}, stop_hook_active=True))
        self.activate(step=5)
        self.assertFalse(self.hook("stop-hook.sh", {}))

    def test_gate_cache_freshness_and_force_advance(self):
        # Isolate actual orchestrator from expensive real companions.
        isolated = self.root / "plugin"
        (isolated / "scripts").mkdir(parents=True)
        orch = isolated / "scripts/k8s-rebase-orchestrator.sh"
        shutil.copy(PLUGIN / "scripts/k8s-rebase-orchestrator.sh", orch)
        for name in ("step1-rebase", "step2-compilation", "step3-autofix", "step4-verification"):
            directory = isolated / "gates" / name
            directory.mkdir(parents=True)
            (directory / "check.md").write_text("fixture gate\n")

        def run(action, *args):
            return self.run_cmd("bash", str(orch), action, str(self.repo), *args)

        result = run("init", "1.36.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STEP_FILE: steps/step1-rebase.md", result.stdout)
        self.assertEqual(run("gates").returncode, 1)
        writer = PLUGIN / "scripts/write-gate-report.sh"
        self.run_cmd("bash", str(writer), str(self.repo), "step1-check", "FAIL", "1", "fixture", check=True)
        result = run("gates")
        self.assertEqual(result.returncode, 0)
        self.assertIn("FAIL", result.stdout)
        self.run_cmd("git", "commit", "--allow-empty", "-qm", "new HEAD", check=True)
        self.assertEqual(run("gates").returncode, 1)
        for rc in (1, 1, 2):
            result = run("advance")
            self.assertEqual(result.returncode, rc, result.stderr)
        self.assertIn("FORCE_ADVANCE", result.stdout)
        self.assertIn("CURRENT: 2", run("status").stdout)
        state = self.repo / ".rebase-tmp"
        self.assertTrue((state / "gates/step1-check.report").exists())
        self.assertFalse((state / ".advance-attempts-step2").exists())
        self.assertTrue((state / "status/INCOMPLETE").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
