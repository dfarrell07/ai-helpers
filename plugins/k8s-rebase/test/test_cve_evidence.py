#!/usr/bin/env python3
"""Offline CVE coverage checks using real Git histories and injected OSV replies."""

import importlib.util
import base64
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


PLUGIN = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cve_evidence", PLUGIN / "scripts/cve-evidence.py")
CVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CVE)
GATE = PLUGIN / "gates/step4-verification/dep-cve-check.sh"
CHECKSUM = "h1:" + base64.b64encode(bytes(32)).decode()


def advisory(identifier):
    return {"id": identifier, "modified": "2026-09-24T00:00:00Z", "affected": [],
            "summary": "Reviewer must assess severity and reachability"}


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="k8s-cve-evidence-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo with spaces"
        self.repo.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GIT_", "BASH_FUNC_"))}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        BASH_ENV="", ENV="")
        self.run_cmd("git", "init", "-qb", "main")
        self.run_cmd("git", "config", "user.name", "Gate Fixture")
        self.run_cmd("git", "config", "user.email", "gate@example.invalid")

    def run_cmd(self, *args):
        return subprocess.run(args, cwd=self.repo, env=self.env, text=True,
                              capture_output=True, check=True, timeout=20)

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def sums(self, path, *entries):
        self.write(path, "".join(f"{module} {version} {CHECKSUM}\n" for module, version in entries))

    def commit(self):
        self.run_cmd("git", "add", ".")
        self.run_cmd("git", "commit", "-qm", "fixture")
        return self.run_cmd("git", "rev-parse", "HEAD").stdout.strip()

    def baseline(self):
        self.base = self.commit()
        self.run_cmd("git", "switch", "-qc", "rebase")

    def test_nested_modules_added_removed_retained_versions_and_vendor_exclusion(self):
        self.sums("go.sum", ("example.invalid/shared", "v1.0.0"),
                  ("example.invalid/shared", "v1.1.0"), ("example.invalid/drop", "v2.0.0"))
        self.sums("nested space/go.sum", ("example.invalid/shared", "v3.0.0"))
        self.sums("vendor/tool/go.sum", ("example.invalid/ignored", "v1.0.0"))
        self.sums("nested/vendor/go.sum", ("example.invalid/ignored", "v1.0.0"))
        self.sums("deleted/go.sum", ("example.invalid/deleted", "v1.0.0"))
        self.baseline()
        self.sums("go.sum", ("example.invalid/shared", "v1.0.0"),
                  ("example.invalid/shared", "v1.2.0"), ("example.invalid/new", "v1.0.0"),
                  ("example.invalid/metadata", "v5.0.0/go.mod"))
        self.sums("nested space/go.sum", ("example.invalid/shared", "v3.1.0"))
        self.sums("vendor/tool/go.sum", ("example.invalid/ignored", "v2.0.0"))
        self.sums("nested/vendor/go.sum", ("example.invalid/ignored", "v2.0.0"))
        (self.repo / "deleted/go.sum").unlink()
        self.sums("added/go.sum", ("example.invalid/new", "v1.0.0"))
        head = self.commit()
        requested = []

        def fetch(path, payload=None):
            self.assertEqual(path, "querybatch")
            requested.extend((q["package"]["name"], q["version"]) for q in payload["queries"])
            return {"results": [{} for _ in payload["queries"]]}

        result = CVE.collect(self.repo, self.base, head, fetch)
        self.assertEqual(result["coverage"], "COMPLETE")
        self.assertEqual(result["files"], ["added/go.sum", "deleted/go.sum", "go.sum", "nested space/go.sum"])
        self.assertEqual(len(result["inventory"]), 6)
        root = next(item for item in result["inventory"]
                    if item["go_sum"] == "go.sum" and item["module"] == "example.invalid/shared")
        self.assertEqual(root["old_versions"], ["v1.0.0", "v1.1.0"])
        self.assertEqual(root["new_versions"], ["v1.0.0", "v1.2.0"])
        self.assertEqual(root["added_versions"], ["v1.2.0"])
        self.assertEqual(root["removed_versions"], ["v1.1.0"])
        self.assertEqual(len(requested), len(set(requested)))
        self.assertEqual(len(requested), 8)
        self.assertIn(("example.invalid/deleted", "v1.0.0"), requested)
        self.assertNotIn("ignored", json.dumps(result))
        self.assertNotIn("metadata", json.dumps(result))

    def test_checksum_only_change_does_not_invent_version_change(self):
        self.sums("go.sum", ("example.invalid/a", "v1.0.0"))
        self.baseline()
        other_checksum = "h1:" + base64.b64encode(bytes([1]) * 32).decode()
        self.write("go.sum", f"example.invalid/a v1.0.0 {other_checksum}\n")
        transport = mock.Mock(side_effect=AssertionError("no network needed"))
        result = CVE.collect(self.repo, self.base, self.commit(), transport)
        self.assertEqual(result["coverage"], "COMPLETE")
        self.assertEqual(result["inventory"], [])

    def test_missing_base_and_malformed_sum_remain_incomplete(self):
        self.sums("go.sum", ("example.invalid/a", "v1.0.0"))
        self.baseline()
        self.write("go.sum", "not a valid checksum line\n")
        head = self.commit()
        for base in ("", self.base, "missing-revision"):
            with self.subTest(base=base):
                result = CVE.collect(self.repo, base, head, mock.Mock(side_effect=AssertionError))
                self.assertEqual(result["coverage"], "INCOMPLETE")
                self.assertTrue(result["errors"])
                self.assertIn("COVERAGE: INCOMPLETE", CVE.render(result))

    def test_malformed_versions_and_hashes_are_not_silently_queried(self):
        for line in (f"example.invalid/a vgarbage {CHECKSUM}",
                     "example.invalid/a v1.0.0 h1:bad-base64",
                     "example.invalid/a v1.0.0 h1:YWJj"):
            with self.subTest(line=line), self.assertRaises(ValueError):
                CVE.checksums(line, "nested/go.sum")

    def test_partial_query_or_advisory_failure_sets_overall_incomplete(self):
        self.sums("go.sum", ("example.invalid/a", "v1.0.0"))
        self.baseline()
        self.sums("go.sum", ("example.invalid/a", "v2.0.0"))
        head = self.commit()
        for replies in ([{"results": [{}]}],
                        [{"results": [{}, {"vulns": [{"id": "GO-missing"}]}]}, OSError("HTTP 404")]):
            with self.subTest(replies=replies):
                result = CVE.collect(self.repo, self.base, head, mock.Mock(side_effect=replies))
                self.assertEqual(result["coverage"], "INCOMPLETE")
                text = CVE.render(result)
                self.assertIn("EXPECTED_QUERIES: 2", text)
                self.assertIn("COVERAGE: INCOMPLETE", text)
                self.assertNotIn("VERDICT:", text)

    def test_companion_writes_fresh_evidence_but_never_a_verdict(self):
        self.sums("go.sum", ("example.invalid/a", "v1.0.0"))
        self.baseline()
        self.write("README", "No changed module versions\n")
        head = self.commit()
        output = self.run_cmd("bash", str(GATE), str(self.repo)).stdout
        directory = self.repo / ".rebase-tmp/gates"
        evidence = (directory / "step4-dep-cve-check.evidence").read_text()
        self.assertTrue(evidence.startswith(f"HEAD: {head}\n"))
        self.assertIn(f"SCAN_HEAD: {head}\n", evidence)
        self.assertIn("COVERAGE: COMPLETE", evidence)
        self.assertIn("EXPECTED_QUERIES: 0", evidence)
        self.assertIn("PENDING: step4-dep-cve-check", output)
        self.assertNotIn("VERDICT:", evidence)
        self.assertFalse((directory / "step4-dep-cve-check.report").exists())
        self.assertEqual(self.run_cmd("git", "diff", "HEAD").stdout, "")


class OSVCoverageTests(unittest.TestCase):
    PAIRS = [("example.invalid/a", "v1.0.0"), ("example.invalid/a", "v2.0.0")]

    def test_batch_missing_extra_and_error_results_are_not_clean(self):
        replies = [{}, {"error": "unavailable"}, {"results": []},
                   {"results": [{}]}, {"results": [{}, {}, {}]},
                   {"results": [None, {"vulns": None}]},
                   {"results": [{"error": "rate limited"}, {"unexpected": True}]},
                   {"results": [{"vulns": [{}]}, {"next_page_token": 4}]}]
        for reply in replies:
            with self.subTest(reply=reply):
                queries, _ = CVE.osv_evidence(self.PAIRS, lambda *args: reply)
                self.assertTrue(all(item["status"] == "INCOMPLETE" for item in queries))
                self.assertTrue(all(item.get("error") for item in queries))

    def test_http_and_malformed_json_errors_do_not_stop_other_batches(self):
        for error in (OSError("HTTP 503"), json.JSONDecodeError("invalid", "<html>", 0),
                      CVE.http.client.IncompleteRead(b"partial", 40)):
            with self.subTest(error=error):
                fetch = mock.Mock(side_effect=[error, {"results": [{}]}])
                queries, _ = CVE.osv_evidence(self.PAIRS, fetch, batch_size=1)
                self.assertEqual([q["status"] for q in queries], ["INCOMPLETE", "COMPLETE"])

    def test_pagination_and_full_advisories_preserve_old_new_findings(self):
        calls = []

        def fetch(path, payload=None):
            calls.append((path, payload))
            if path.startswith("vulns/"):
                return advisory(path.split("/", 1)[1])
            if len(calls) == 1:
                return {"results": [{"vulns": [{"id": "GO-old"}], "next_page_token": "next"},
                                    {"vulns": [{"id": "GO-new"}]}]}
            self.assertEqual(payload["queries"], [{"package": {"name": "example.invalid/a", "ecosystem": "Go"},
                                                   "version": "v1.0.0", "page_token": "next"}])
            return {"results": [{"vulns": [{"id": "GO-shared"}, {"id": "GO-old"}]}]}

        queries, advisories = CVE.osv_evidence(self.PAIRS + self.PAIRS, fetch)
        self.assertEqual(len(queries), 2)
        self.assertTrue(all(q["status"] == "COMPLETE" for q in queries))
        self.assertEqual(queries[0]["advisory_ids"], ["GO-old", "GO-shared"])
        self.assertEqual(queries[1]["advisory_ids"], ["GO-new"])
        self.assertEqual(len(advisories), 3)
        self.assertTrue(all(a["status"] == "COMPLETE" and "record" in a for a in advisories))

    def test_failed_or_repeating_later_page_retains_finding_and_incomplete_status(self):
        for second in (OSError("timeout"), {"results": [{"next_page_token": "again"}]}):
            with self.subTest(second=second):
                fetch = mock.Mock(side_effect=[{"results": [{"vulns": [{"id": "GO-known"}],
                                                             "next_page_token": "again"}]},
                                              second, advisory("GO-known")])
                queries, advisories = CVE.osv_evidence(self.PAIRS[:1], fetch)
                self.assertEqual(queries[0]["status"], "INCOMPLETE")
                self.assertEqual(queries[0]["advisory_ids"], ["GO-known"])
                self.assertEqual(advisories[0]["status"], "COMPLETE")

    def test_page_limit_is_explicit_incomplete(self):
        fetch = mock.Mock(return_value={"results": [{"next_page_token": "more"}]})
        queries, _ = CVE.osv_evidence(self.PAIRS[:1], fetch, max_pages=1)
        self.assertEqual(queries[0]["status"], "INCOMPLETE")
        self.assertIn("page limit", queries[0]["error"])

    def test_missing_or_wrong_advisory_details_are_incomplete(self):
        for reply in (OSError("HTTP 404"), {"id": "GO-found"}, advisory("GO-other")):
            with self.subTest(reply=reply):
                fetch = mock.Mock(side_effect=[{"results": [{"vulns": [{"id": "GO-found"}]}]}, reply])
                queries, advisories = CVE.osv_evidence(self.PAIRS[:1], fetch)
                self.assertEqual(queries[0]["status"], "COMPLETE")
                self.assertEqual(advisories[0]["status"], "INCOMPLETE")

    def test_http_transport_rejects_non_json_and_uses_read_only_query_endpoint(self):
        with mock.patch.object(CVE.urllib.request, "urlopen", return_value=io.BytesIO(b"<html>")) as opened:
            with self.assertRaises(json.JSONDecodeError):
                CVE.fetch_json("querybatch", {"queries": []})
            request = opened.call_args.args[0]
            self.assertEqual(request.full_url, "https://api.osv.dev/v1/querybatch")
            self.assertEqual(json.loads(request.data), {"queries": []})
            self.assertEqual(opened.call_args.kwargs["timeout"], 30)


if __name__ == "__main__":
    unittest.main()
