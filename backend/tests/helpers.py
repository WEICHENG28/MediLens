"""测试辅助：构造合成报告（全部为合成数据，非真实患者）。"""
from app.schemas import AnalyzeRequest


def item(label, value, unit=None, ref=None, status="auto_accepted", **kw):
    return {"original_label": label, "raw_value": value, "unit": unit, "reference_text": ref, "review_status": status, **kw}


def req(items, answers=None, history=None, test_date="2026-10-01"):
    return AnalyzeRequest.model_validate(
        {"report": {"test_date": test_date, "items": items}, "answers": answers or {}, "history": history or []}
    )


def normal_urinalysis(**overrides):
    base = {
        "GLU": item("葡萄糖(GLU)", "阴性", ref="阴性"),
        "KET": item("酮体(KET)", "阴性", ref="阴性"),
        "PRO": item("蛋白质(PRO)", "阴性", ref="阴性"),
        "LEU": item("白细胞(LEU)", "阴性", ref="阴性"),
        "NIT": item("亚硝酸盐(NIT)", "阴性", ref="阴性"),
        "BLD": item("隐血(BLD)", "阴性", ref="阴性"),
        "SG": item("比重(SG)", "1.020", ref="1.003-1.030"),
        "PH": item("酸碱度(pH)", "6.0", ref="4.5-8.0"),
    }
    base.update(overrides)
    return [v for v in base.values() if v is not None]
