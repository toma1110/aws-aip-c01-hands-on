from h3.scenario import leak_count, mask, run


def test_baseline_exposes_all_four_paths():
    result = run("baseline")
    assert result["pass"] is True
    assert result["leak_count"] == 8


def test_improved_protects_all_four_paths():
    result = run("improved")
    assert result["pass"] is True
    assert result["leak_count"] == 0


def test_mask_email_and_synthetic_key():
    assert mask("john@example.com / SYNTH-KEY-4821") == "{EMAIL} / {SYNTHETIC_KEY}"


def test_nested_tool_parameters_are_masked():
    assert leak_count(mask({"to": "john@example.com", "code": "SYNTH-KEY-4821"})) == 0
