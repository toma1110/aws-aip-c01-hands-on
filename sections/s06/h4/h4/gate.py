import json
from pathlib import Path


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def evaluate(dataset, config, scenario):
    if dataset["dataset_version"] != config["dataset_version"]:
        raise ValueError("dataset_version mismatch")
    cases = dataset["scenarios"][scenario]
    if not cases:
        raise ValueError("scenario has no cases")

    baseline_avg = sum(c["baseline"]["quality"] for c in cases) / len(cases)
    candidate_avg = sum(c["candidate"]["quality"] for c in cases) / len(cases)
    hard, warnings, pending = [], [], []
    for case in cases:
        candidate = case["candidate"]
        if case["critical"] and candidate["quality"] < config["hard"]["critical_min_quality"]:
            hard.append({"case_id": case["case_id"], "reason": "critical_quality_below_threshold"})
        if not candidate.get("required_check_passed", False):
            hard.append({"case_id": case["case_id"], "reason": "required_check_failed"})
        latency_delta = (candidate["latency_ms"] - case["baseline"]["latency_ms"]) / case["baseline"]["latency_ms"]
        cost_delta = (candidate["cost_usd"] - case["baseline"]["cost_usd"]) / case["baseline"]["cost_usd"]
        if latency_delta > config["warning"]["max_latency_increase_ratio"]:
            warnings.append({"case_id": case["case_id"], "metric": "latency", "increase_ratio": round(latency_delta, 4)})
        if cost_delta > config["warning"]["max_cost_increase_ratio"]:
            warnings.append({"case_id": case["case_id"], "metric": "cost", "increase_ratio": round(cost_delta, 4)})
        if case["manual_review_required"]:
            review_status = case.get("manual_review_status")
            if review_status == "pending":
                pending.append(case["case_id"])
            elif review_status == "rejected":
                hard.append({"case_id": case["case_id"], "reason": "manual_review_rejected"})
            elif review_status != "approved":
                hard.append({"case_id": case["case_id"], "reason": "manual_review_status_invalid"})

    if hard:
        decision = "ROLLBACK"
    elif pending:
        decision = "HOLD"
    elif warnings:
        decision = "PASS_WITH_WARNINGS"
    else:
        decision = "PASS"
    return {
        "scenario": scenario,
        "dataset_version": dataset["dataset_version"],
        "config_version": config["config_version"],
        "average_quality": {"baseline": round(baseline_avg, 4), "candidate": round(candidate_avg, 4)},
        "average_quality_improved": candidate_avg > baseline_avg,
        "hard_failures": hard,
        "warnings": warnings,
        "manual_review_pending": pending,
        "decision": decision,
        "rollback": decision == "ROLLBACK",
    }
