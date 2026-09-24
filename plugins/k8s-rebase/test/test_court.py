#!/usr/bin/env python3
"""Offline integration checks for court scope and cached review identity."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PLUGIN = Path(__file__).resolve().parents[1]
HARNESS = PLUGIN / "test/test-skill.sh"


@unittest.skipUnless(shutil.which("yq") and shutil.which("jq"), "requires yq and jq")
class CourtHarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="k8s-court-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repos/acme/demo"
        self.repo.mkdir(parents=True)
        self.plugin = self.root / "plugin"
        (self.plugin / "gates/step1-rebase").mkdir(parents=True)
        (self.plugin / "test/.matrix-state/run-inputs").mkdir(parents=True)
        (self.plugin / "test/.matrix-state/court").mkdir(parents=True)
        (self.plugin / "gates/step1-rebase/court-fixture.md").write_text("fixture gate\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.prompts = self.root / "prompts"
        self.prompts.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        for key in list(self.env):
            if key.startswith(("GIT_", "BASH_FUNC_")):
                del self.env[key]
        self.env.update(
            PLUGIN_DIR=str(self.plugin),
            REPOS_DIR=str(self.root / "repos"),
            CONFIG_FILE=str(self.plugin / "test/config-1.36.yaml"),
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            COURT_MODEL="claude-sonnet-4-6",
            PROMPT_DIR=str(self.prompts),
        )

        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Court Fixture")
        self.git("config", "user.email", "court@example.invalid")
        (self.repo / "base.txt").write_text("base\n")
        self.commit("common base")
        self.common_base = self.sha()

        self.git("switch", "-qc", "known-good", self.common_base)
        (self.repo / "human.txt").write_text("human reference\n")
        self.commit("reference change")
        self.known_good = self.sha()

        self.git("switch", "-qc", "input", self.common_base)
        (self.repo / "input.txt").write_text("pre-existing input change\n")
        self.commit("input commit")
        self.run_base = self.sha()

        self.git("switch", "-qc", "bump1.36", self.run_base)
        (self.repo / "agent.txt").write_text("result change\n")
        self.commit("agent result")
        self.result = self.sha()
        self.git("switch", "-q", "main")

        config = self.plugin / "test/config-1.36.yaml"
        config.write_text(
            "version: 1.36.2\n"
            "max_concurrent: 1\n"
            "repos:\n"
            f"  acme/demo:\n    from_commit: {self.common_base}\n"
            "    known_good: known-good\n"
        )
        # The run's captured base takes precedence over a subsequently changed config.
        inputs = self.plugin / "test/.matrix-state/run-inputs/1.36.2_acme_demo.json"
        inputs.write_text(json.dumps({
            "version": "1.36.2", "repo": "acme/demo", "base_ref": self.run_base,
            "started_at": 1, "spec": "none", "recorded_at": "2026-09-24T00:00:00Z",
            "workflow_verdict": "PASS", "result_ref": self.result,
        }))
        self.state = self.plugin / "test/.matrix-state"

        claude = self.bin / "claude"
        claude.write_text(
            "#!/bin/bash\n"
            'if [[ "${1:-}" == "agents" ]]; then echo "[]"; exit 0; fi\n'
            'if [[ "${1:-}" == "--bg" ]]; then echo "Session backgrounded 1234abcd"; exit 0; fi\n'
            "prompt=$(cat)\n"
            'printf "%s\\n" "$prompt" > "$PROMPT_DIR/prompt-$BASHPID.txt"\n'
            '[[ "${COURT_INCONCLUSIVE:-}" == "1" ]] && exit 0\n'
            'padding=$(printf \'%0256d\' 0)\n'
            'if [[ "$prompt" == *"You are the PROSECUTION."* ]]; then printf "PROSECUTION %s\\n" "$padding"; '
            'elif [[ "$prompt" == *"You are the DEFENSE."* ]]; then printf "DEFENSE %s\\n" "$padding"; '
            'elif [[ "$prompt" == *"Fact-check only."* ]]; then printf "FACT CHECK %s\\n" "$padding"; '
            'elif [[ "${COURT_FAIL:-}" == "1" ]]; then printf "VERDICT: FAIL\\nVERIFIED: fixture.txt@fixture\\nEVIDENCE: fixture review %s\\n" "$padding"; '
            'else printf "VERDICT: PASS\\nEVIDENCE: fixture review %s\\n" "$padding"; fi\n'
        )
        claude.chmod(0o755)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              text=True, capture_output=True, env=self.env)

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)

    def sha(self):
        return self.git("rev-parse", "HEAD").stdout.strip()

    def harness(self, *args):
        return subprocess.run(["bash", str(HARNESS), *args], cwd=PLUGIN, env=self.env,
                              text=True, capture_output=True, timeout=60)

    def prompt_files(self):
        return sorted(self.prompts.glob("prompt-*.txt"))

    def court_result(self):
        return self.state / "court/1.36.2_acme_demo"

    def test_court_uses_run_base_and_recourts_changed_inputs(self):
        (self.state / "results.tsv").write_text(
            "2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tPASS\tfixture complete\n"
        )
        result = self.harness("results", "acme/demo", "--court")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DIFF REVIEW VERDICT: PASS", result.stderr)
        prompt_text = "\n".join(path.read_text() for path in self.prompt_files())
        self.assertIn(f"BASE_REF: {self.run_base} (the exact commit from which this run started)", prompt_text)
        self.assertNotIn(f"BASE_REF: {self.common_base} (the exact commit from which this run started)", prompt_text)

        state = json.loads(self.court_result().read_text())
        self.assertEqual(state["base_ref"], self.run_base)
        self.assertEqual(state["result_ref"], self.result)
        self.assertEqual(state["known_good_ref"], self.known_good)
        self.assertEqual(state["verdict"], "PASS")

        # A matching cached review must not call the model again.
        results = self.state / "results.tsv"
        results.write_text(
            f"2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tPASS\tfixture complete\n"
        )
        prompt_count = len(self.prompt_files())
        cached = self.harness("court-all")
        self.assertEqual(cached.returncode, 0, cached.stderr)
        self.assertIn("No pending court reviews.", cached.stdout)
        self.assertEqual(len(self.prompt_files()), prompt_count)

        # A changed result SHA invalidates the cached court vote.
        self.git("switch", "bump1.36")
        (self.repo / "later.txt").write_text("later result change\n")
        self.commit("later result change")
        changed = self.harness("court-all")
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertIn("recorded PASS does not match current run/result; skipping court review", changed.stderr)
        self.assertEqual(len(self.prompt_files()), prompt_count)
        state = json.loads(self.court_result().read_text())
        self.assertEqual(state["result_ref"], self.result)

    def test_explicit_from_commit_overrides_saved_metadata(self):
        (self.plugin / "test/.matrix-state/run-inputs/1.36.2_acme_demo.json").unlink()
        (self.state / "results.tsv").write_text(
            "2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tPASS\tfixture complete\n"
        )
        result = self.harness("results", "acme/demo", "--court", "--from-commit", self.common_base)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("Workflow run verdict: UNVERIFIED", result.stdout)
        prompt_text = "\n".join(path.read_text() for path in self.prompt_files())
        self.assertIn(f"BASE_REF: {self.common_base} (the exact commit from which this run started)", prompt_text)
        state = json.loads(self.court_result().read_text())
        self.assertEqual(state["base_ref"], self.common_base)
        self.assertEqual(state["base_source"], "explicit")

        (self.state / "results.tsv").write_text(
            f"2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tPASS\tfixture complete\n"
        )
        shown = self.harness("results")
        self.assertEqual(shown.returncode, 1, shown.stdout + shown.stderr)
        self.assertIn("DIFF REVIEW", shown.stdout)
        self.assertIn("UNVERIFIED", shown.stdout)
        self.assertIn("OVERALL (run + diff review): FAIL", shown.stdout)
        self.assertNotIn("stale", shown.stdout)

    def test_missing_run_base_fails_closed_without_merge_base_guess(self):
        (self.plugin / "test/.matrix-state/run-inputs/1.36.2_acme_demo.json").unlink()
        result = self.harness("results", "acme/demo", "--court")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("exact run starting commit is unavailable", result.stderr)
        self.assertFalse(self.court_result().exists())
        self.assertEqual(self.prompt_files(), [])

    def test_inconclusive_review_replaces_old_cached_pass(self):
        self.court_result().write_text(json.dumps({"verdict": "PASS"}))
        (self.state / "results.tsv").write_text(
            "2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tPASS\tfixture complete\n"
        )
        env = dict(self.env, COURT_INCONCLUSIVE="1")
        result = subprocess.run(
            ["bash", str(HARNESS), "results", "acme/demo", "--court"],
            cwd=PLUGIN, env=env, text=True, capture_output=True, timeout=60,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        state = json.loads(self.court_result().read_text())
        self.assertEqual(state["verdict"], "INCONCLUSIVE")
        self.assertEqual(state["base_ref"], self.run_base)

    def test_failed_court_propagates_nonzero_status(self):
        (self.state / "results.tsv").write_text(
            "2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tPASS\tfixture complete\n"
        )
        env = dict(self.env, COURT_FAIL="1")
        result = subprocess.run(
            ["bash", str(HARNESS), "results", "acme/demo", "--court"],
            cwd=PLUGIN, env=env, text=True, capture_output=True, timeout=60,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("DIFF REVIEW VERDICT: FAIL", result.stderr)
        state = json.loads(self.court_result().read_text())
        self.assertEqual(state["verdict"], "FAIL")

    def test_diff_review_pass_does_not_override_failed_workflow(self):
        (self.state / "results.tsv").write_text(
            "2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tFAIL\tno gates completed\n"
        )
        inputs = self.plugin / "test/.matrix-state/run-inputs/1.36.2_acme_demo.json"
        run = json.loads(inputs.read_text())
        run.update(spec="none", recorded_at="2026-09-24T00:00:00Z",
                   workflow_verdict="FAIL", result_ref=self.result)
        inputs.write_text(json.dumps(run))
        result = self.harness("results", "acme/demo", "--court")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("DIFF REVIEW VERDICT: PASS", result.stderr)
        self.assertIn("Workflow run verdict: FAIL", result.stdout)
        state = json.loads(self.court_result().read_text())
        self.assertEqual(state["verdict"], "PASS")

    def test_diff_only_court_ignores_stale_matrix_workflow_row(self):
        (self.state / "results.tsv").write_text(
            "2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tFAIL\tprior harness run failed\n"
        )
        result = self.harness("results", "acme/demo", "--court", "--from-commit",
                              self.run_base, "--diff-only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DIFF REVIEW VERDICT: PASS", result.stderr)
        self.assertIn("Workflow run verdict: NOT INCLUDED (diff-only review", result.stdout)
        self.assertNotIn("Workflow run verdict: FAIL", result.stdout)
        state = json.loads(self.court_result().read_text())
        self.assertEqual(state["verdict"], "PASS")
        self.assertEqual(state["base_ref"], self.run_base)

    def test_unrecorded_run_gets_diagnostic_review_only(self):
        result = self.harness("results", "acme/demo", "--court", "--from-commit", self.run_base)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("DIFF REVIEW VERDICT: PASS", result.stderr)
        self.assertIn("Workflow run verdict: UNRECORDED", result.stdout)
        state = json.loads(self.court_result().read_text())
        self.assertEqual(state["verdict"], "PASS")
        self.assertEqual(state["base_source"], "explicit")

    def test_force_advance_marker_forces_workflow_run_fail(self):
        worktree = self.repo / ".claude/worktrees/rebase-run"
        worktree.parent.mkdir(parents=True)
        self.git("worktree", "add", "-q", "-b", "worktree-k8s-rebase-1.36-test",
                 str(worktree), "bump1.36")
        gates = worktree / ".rebase-tmp/gates"
        gates.mkdir(parents=True)
        (gates / "step1-court-fixture.report").write_text("VERDICT: PASS\n")
        # Claude can keep gate artifacts in a linked worktree while the
        # orchestrator's force-advance marker remains in the main checkout.
        status = self.repo / ".rebase-tmp/status"
        status.mkdir(parents=True)
        (status / "INCOMPLETE").write_text("force advanced\n")
        running = self.state / "running"
        running.mkdir(parents=True)
        (running / "1.36.2_acme_demo").write_text("none\t0\tdead-session\t1.36.2\n")

        result = self.harness("results")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        rows = (self.state / "results.tsv").read_text()
        self.assertIn("\tFAIL\t", rows)
        self.assertIn("force-advance INCOMPLETE marker", rows)

    def test_overall_results_wait_for_required_diff_review(self):
        (self.state / "results.tsv").write_text(
            f"2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tPASS\tfixture complete\n"
        )
        result = self.harness("results")
        self.assertEqual(result.returncode, 1)
        self.assertIn("pending", result.stdout)
        self.assertIn("OVERALL (run + diff review): FAIL", result.stdout)

    def test_exploration_without_reference_cannot_qualify(self):
        config = Path(self.env["CONFIG_FILE"])
        config.write_text(config.read_text().replace("    known_good: known-good\n", ""))
        (self.state / "results.tsv").write_text(
            "2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tPASS\tfixture complete\n"
        )
        result = self.harness("results")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("no reference", result.stdout)
        self.assertIn("known_good not configured", result.stdout)
        self.assertIn("OVERALL (run + diff review): FAIL", result.stdout)
        # An old resolved-ref cache cannot supply a deliberately absent input.
        (self.state / "known_good_resolved_acme_demo_1_36_2").write_text("known-good\n")
        result = self.harness("results", "acme/demo", "--court")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("no known-good reference configured", result.stderr)
        self.assertEqual(self.prompt_files(), [])

    def test_no_runs_cannot_qualify(self):
        result = self.harness("results")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("No results yet", result.stdout)
        self.assertNotIn("OVERALL (run + diff review): PASS", result.stdout)

    def test_old_pass_row_cannot_certify_new_result_commit(self):
        (self.state / "results.tsv").write_text(
            "2026-09-24T00:00:00Z\t1.36.2\tnone\tacme/demo\tPASS\tfixture complete\n"
        )
        self.git("switch", "bump1.36")
        (self.repo / "new-run.txt").write_text("new checkout result\n")
        self.commit("new result without workflow record")

        result = self.harness("results")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("UNVERIFIED", result.stdout)
        self.assertIn("OVERALL (run + diff review): FAIL", result.stdout)

    def test_test_launch_records_exact_checked_out_base(self):
        result = self.harness("test", "none", "acme/demo", "--version", "1.36.2",
                              "--from-commit", self.run_base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        inputs = json.loads(
            (self.plugin / "test/.matrix-state/run-inputs/1.36.2_acme_demo.json").read_text()
        )
        self.assertEqual(inputs["base_ref"], self.run_base)
        self.assertEqual(inputs["repo"], "acme/demo")
        self.assertGreater(inputs["started_at"], 0)


if __name__ == "__main__":
    unittest.main()
