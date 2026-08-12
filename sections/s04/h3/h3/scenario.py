import argparse
import json
import re
import sys
from pathlib import Path

SYNTHETIC = {
    "request": "連絡先は john@example.com、確認コードは SYNTH-KEY-4821 です。",
    "retrieved_reference": "合成顧客 john@example.com の確認コード SYNTH-KEY-4821",
    "tool_parameter": {"recipient": "john@example.com", "code": "SYNTH-KEY-4821"},
}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
SYNTH_KEY = re.compile(r"SYNTH-KEY-[0-9]{4}")


def mask(value):
    if isinstance(value, dict):
        return {key: mask(item) for key, item in value.items()}
    if isinstance(value, str):
        return SYNTH_KEY.sub("{SYNTHETIC_KEY}", EMAIL.sub("{EMAIL}", value))
    return value


def leak_count(value):
    text = json.dumps(value, ensure_ascii=False)
    return len(EMAIL.findall(text)) + len(SYNTH_KEY.findall(text))


def run(phase):
    if phase == "baseline":
        paths = {
            "model_output": SYNTHETIC["request"],
            "application_log": SYNTHETIC["request"],
            "tool_parameter": SYNTHETIC["tool_parameter"],
            "retrieved_reference": SYNTHETIC["retrieved_reference"],
        }
    else:
        paths = {
            "model_output": mask(SYNTHETIC["request"]),
            "application_log": "request accepted; sensitive values omitted",
            "tool_parameter": mask(SYNTHETIC["tool_parameter"]),
            "retrieved_reference": mask(SYNTHETIC["retrieved_reference"]),
        }
    return {
        "phase": phase,
        "fixture": "synthetic-only",
        "paths": paths,
        "leak_count": leak_count(paths),
        "pass": leak_count(paths) == (0 if phase == "improved" else 8),
    }


def cleanup(state_dir):
    path = Path(state_dir)
    if path.exists():
        for item in path.glob("*"):
            if item.is_file():
                item.unlink()
        path.rmdir()
    return {"remaining": [] if not path.exists() else [str(path)]}


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=["baseline", "improved", "cleanup"])
    parser.add_argument("--state-dir", default=".h3-state")
    args = parser.parse_args()
    if args.phase == "cleanup":
        result = cleanup(args.state_dir)
    else:
        result = run(args.phase)
        path = Path(args.state_dir)
        path.mkdir(exist_ok=True)
        (path / f"{args.phase}.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
