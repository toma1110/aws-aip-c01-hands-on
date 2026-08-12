import argparse
import json
import os
import shutil
import sys
from pathlib import Path

from .gate import evaluate, load_json

ROOT = Path(__file__).resolve().parents[1]
STATE_ROOT = ROOT / ".h4-state"


def resolve_state_dir(raw):
    requested = Path(raw)
    if raw == ".h4-state":
        candidate = STATE_ROOT
    elif requested.is_absolute():
        candidate = requested
    elif requested.parts and requested.parts[0] == ".h4-state":
        candidate = ROOT / requested
    else:
        candidate = STATE_ROOT / requested
    lexical = Path(os.path.abspath(candidate))
    state_root = Path(os.path.abspath(STATE_ROOT))
    if lexical != state_root and state_root not in lexical.parents:
        raise ValueError("output-dir must be inside the dedicated .h4-state directory")
    current = state_root
    relative_parts = lexical.relative_to(state_root).parts
    for part in ((), *[(p,) for p in relative_parts]):
        check = state_root if not part else current / part[0]
        current = check
        if check.exists() and check.is_symlink():
            raise ValueError("output-dir symlink is not allowed")
    return lexical


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario", choices=["baseline", "average-pass-critical-fail", "warning-only", "manual-review", "fixed", "cleanup"])
    parser.add_argument("--output-dir", default=".h4-state")
    args = parser.parse_args()
    try:
        output_dir = resolve_state_dir(args.output_dir)
    except ValueError as exc:
        parser.error(str(exc))
    if args.scenario == "cleanup":
        if output_dir.exists():
            shutil.rmtree(output_dir)
        result = {"remaining": [] if not output_dir.exists() else [str(output_dir)]}
    else:
        result = evaluate(load_json(ROOT / "datasets/golden-v1.json"), load_json(ROOT / "configs/gate-v1.json"), args.scenario)
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / f"{args.scenario}.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    if result.get("decision") in {"ROLLBACK", "HOLD"}:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
