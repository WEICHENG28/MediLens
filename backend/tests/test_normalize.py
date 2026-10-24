import pytest

from app.normalize import map_code, normalize_item, parse_grade, parse_range
from app.schemas import ItemStatus, LabItemIn, Positivity


@pytest.mark.parametrize("label,code", [
    ("GLU", "GLU"), ("尿糖", "GLU"), ("葡萄糖(GLU)", "GLU"), ("U-GLU", "GLU"), ("尿葡萄糖", "GLU"),
    ("KET", "KET"), ("尿酮体", "KET"), ("蛋白质（PRO）", "PRO"), ("尿蛋白", "PRO"),
    ("WBC", "LEU"), ("亚硝酸盐", "NIT"), ("尿微量白蛋白/肌酐", "UACR"), ("ACR", "UACR"),
    ("比重", "SG"), ("pH", "PH"), ("谷丙转氨酶", None),
])
def test_synonym_mapping(label, code):
    assert map_code(label) == code


@pytest.mark.parametrize("raw,grade", [
    ("阴性", 0), ("-", 0), ("±", 0.5), ("+-", 0.5), ("1+", 1), ("+", 1), ("2+", 2), ("++", 2),
    ("3+", 3), ("4+", 4), ("＋＋", 2), ("1+(15)", 1), ("abc", None), ("15", None),
])
def test_grade(raw, grade):
    assert parse_grade(raw) == grade


def test_range_parsing():
    assert parse_range("0-30") == (0, 30)
    assert parse_range("<30") == (None, 30)
    assert parse_range("1.003~1.030") == (1.003, 1.030)
    assert parse_range("阴性") is None


def _n(**kw):
    return normalize_item(LabItemIn(**kw))


def test_qualitative_abnormal_against_report_reference():
    out = _n(original_label="尿蛋白", raw_value="2+", reference_text="阴性")
    assert out.usable and out.positivity == Positivity.positive and out.status == ItemStatus.abnormal


def test_trace_is_abnormal_vs_negative_reference():
    out = _n(original_label="尿蛋白", raw_value="±", reference_text="阴性")
    assert out.positivity == Positivity.trace and out.status == ItemStatus.abnormal


def test_missing_reference_uses_dictionary_and_says_so():
    out = _n(original_label="尿糖", raw_value="阴性")
    assert out.status == ItemStatus.normal and "字典通用参考" in out.status_reason


def test_uacr_unit_conversion_mg_mmol():
    out = _n(original_label="UACR", raw_value="5.0", unit="mg/mmol", reference_text="<3.4")
    assert out.usable and out.normalized_value == pytest.approx(44.2) and out.normalized_unit == "mg/g"
    assert "8.84" in out.conversion_note
    assert out.status == ItemStatus.abnormal
    assert out.raw_value == "5.0"  # 原值不改写


def test_uacr_unknown_unit_is_not_usable():
    out = _n(original_label="UACR", raw_value="45", unit="mg/L")
    assert not out.usable and any("单位" in c for c in out.conflicts)


def test_uacr_missing_unit_not_usable():
    out = _n(original_label="UACR", raw_value="45")
    assert not out.usable


def test_unconfirmed_and_unknown_not_usable():
    for st in ("unknown", "excluded", "needs_confirmation"):
        out = _n(original_label="尿蛋白", raw_value="1+", reference_text="阴性", review_status=st)
        assert not out.usable and out.status == ItemStatus.unknown


def test_numeric_value_in_qualitative_field_is_conflict():
    out = _n(original_label="尿蛋白", raw_value="30", reference_text="阴性")
    assert not out.usable and out.conflicts


def test_implausible_value_triggers_review():
    out = _n(original_label="比重", raw_value="1020", reference_text="1.003-1.030")
    assert not out.usable and "合理范围" in out.status_reason


def test_flag_conflict_triggers_review():
    out = _n(original_label="比重", raw_value="1.020", reference_text="1.003-1.030", abnormal_flag="↑")
    assert not out.usable and "异常标记" in out.status_reason


def test_flag_conflict_kept_when_user_confirmed():
    out = _n(original_label="比重", raw_value="1.020", reference_text="1.003-1.030", abnormal_flag="↑", review_status="confirmed")
    assert out.usable


def test_unsupported_item():
    out = _n(original_label="谷丙转氨酶", raw_value="35")
    assert out.code is None and not out.usable
