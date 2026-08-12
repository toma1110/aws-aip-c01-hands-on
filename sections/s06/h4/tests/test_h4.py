import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

from h4.cli import STATE_ROOT, resolve_state_dir
from h4.gate import evaluate, load_json

ROOT = Path(__file__).resolve().parents[1]


class RegressionGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dataset = load_json(ROOT / "datasets/golden-v1.json")
        cls.config = load_json(ROOT / "configs/gate-v1.json")

    def result(self, scenario):
        return evaluate(self.dataset, self.config, scenario)

    def tearDown(self):
        if STATE_ROOT.exists() and not STATE_ROOT.is_symlink():
            shutil.rmtree(STATE_ROOT)

    def test_fixture_is_synthetic_and_versioned(self):
        self.assertEqual(self.dataset["fixture"], "synthetic-only")
        self.assertEqual(self.dataset["dataset_version"], "golden-v1")

    def test_baseline_passes(self):
        self.assertEqual(self.result("baseline")["decision"], "PASS")

    def test_average_improves_but_critical_failure_rolls_back(self):
        result = self.result("average-pass-critical-fail")
        self.assertTrue(result["average_quality_improved"])
        self.assertEqual(result["decision"], "ROLLBACK")
        self.assertEqual(result["hard_failures"][0]["case_id"], "critical-safety")

    def test_required_check_is_a_hard_gate(self):
        reasons = {item["reason"] for item in self.result("average-pass-critical-fail")["hard_failures"]}
        self.assertIn("required_check_failed", reasons)

    def test_required_check_failure_on_normal_case_is_hard(self):
        dataset = json.loads(json.dumps(self.dataset))
        dataset["scenarios"]["baseline"][0]["candidate"]["required_check_passed"] = False
        self.assertEqual(evaluate(dataset, self.config, "baseline")["decision"], "ROLLBACK")

    def test_warning_does_not_become_hard_failure(self):
        result = self.result("warning-only")
        self.assertEqual(result["decision"], "PASS_WITH_WARNINGS")
        self.assertFalse(result["hard_failures"])

    def test_latency_and_cost_warnings_are_separate(self):
        metrics = {item["metric"] for item in self.result("warning-only")["warnings"]}
        self.assertEqual(metrics, {"latency", "cost"})

    def test_pending_manual_review_holds_release(self):
        result = self.result("manual-review")
        self.assertEqual(result["decision"], "HOLD")
        self.assertEqual(result["manual_review_pending"], ["tone-boundary"])

    def test_rejected_manual_review_rolls_back(self):
        dataset = json.loads(json.dumps(self.dataset))
        dataset["scenarios"]["manual-review"][0]["manual_review_status"] = "rejected"
        self.assertEqual(evaluate(dataset, self.config, "manual-review")["decision"], "ROLLBACK")

    def test_unknown_or_missing_manual_review_status_fails_closed(self):
        for status in ("unknown", None):
            dataset = json.loads(json.dumps(self.dataset))
            case = dataset["scenarios"]["manual-review"][0]
            if status is None:
                case.pop("manual_review_status")
            else:
                case["manual_review_status"] = status
            result = evaluate(dataset, self.config, "manual-review")
            self.assertEqual(result["decision"], "ROLLBACK")
            self.assertIn("manual_review_status_invalid", {x["reason"] for x in result["hard_failures"]})

    def test_fixed_candidate_passes(self):
        result = self.result("fixed")
        self.assertEqual(result["decision"], "PASS")
        self.assertFalse(result["rollback"])

    def test_version_mismatch_fails_closed(self):
        config = json.loads(json.dumps(self.config))
        config["dataset_version"] = "golden-v2"
        with self.assertRaisesRegex(ValueError, "dataset_version mismatch"):
            evaluate(self.dataset, config, "baseline")

    def test_cli_exit_contract(self):
        for scenario, expected in (("baseline", 0), ("warning-only", 0), ("average-pass-critical-fail", 2), ("manual-review", 2)):
            result = subprocess.run([sys.executable, "-m", "h4.cli", scenario, "--output-dir", "exit-test"], cwd=ROOT, env={**os.environ, "PYTHONPATH": str(ROOT)}, capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_state_path_is_constrained(self):
        self.assertEqual(resolve_state_dir("safe-run"), STATE_ROOT / "safe-run")
        for unsafe in (str(ROOT), str(ROOT.parent), str(ROOT.parent / "outside"), "../outside"):
            with self.assertRaisesRegex(ValueError, "dedicated"):
                resolve_state_dir(unsafe)

    def test_state_path_rejects_symlink(self):
        STATE_ROOT.mkdir(exist_ok=True)
        link = STATE_ROOT / "linked"
        with mock.patch("pathlib.Path.exists", return_value=True), mock.patch(
            "pathlib.Path.is_symlink", autospec=True, side_effect=lambda path: path.name == "linked"
        ):
            with self.assertRaisesRegex(ValueError, "symlink"):
                resolve_state_dir("linked/result")


if __name__ == "__main__":
    unittest.main()
