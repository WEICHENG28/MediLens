"""接口数据结构。

所有从客户端收到的都是端侧已识别、用户已确认的结构化指标，不包含原始报告图像。
"""
from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


class ReviewStatus(str, Enum):
    auto_accepted = "auto_accepted"  # OCR 高置信，自动接受
    confirmed = "confirmed"  # 用户在局部确认中选择/更正
    unknown = "unknown"  # 用户选择「无法确认」
    excluded = "excluded"  # 用户排除，不参与判读
    needs_confirmation = "needs_confirmation"  # 尚未确认（不应进入确定性规则）


class ImageBox(BaseModel):
    """原图坐标（归一化，基于旋转/裁剪后的图像）。服务端只透传，不使用图像。"""

    page: int = 1
    x: float
    y: float
    w: float
    h: float


class LabItemIn(BaseModel):
    code: str | None = None
    original_label: str
    raw_value: str | None = None
    unit: str | None = None
    reference_text: str | None = None
    abnormal_flag: str | None = None  # 报告上的 ↑ ↓ * 等
    ocr_confidence: float | None = None
    review_status: ReviewStatus = ReviewStatus.auto_accepted
    image_box: ImageBox | None = None


class Positivity(str, Enum):
    negative = "negative"
    trace = "trace"
    positive = "positive"
    unknown = "unknown"


class ItemStatus(str, Enum):
    normal = "normal"  # 在报告参考范围内
    abnormal = "abnormal"  # 超出报告参考范围
    unknown = "unknown"  # 无法判断（未确认/缺参考范围/无法解析）


class LabItemOut(BaseModel):
    code: str | None
    name: str
    original_label: str
    raw_value: str | None
    unit: str | None
    reference_text: str | None
    review_status: ReviewStatus
    usable: bool  # 是否可进入确定性规则
    grade: float | None = None  # 定性等级
    positivity: Positivity = Positivity.unknown
    numeric_value: float | None = None  # 原值数值
    normalized_value: float | None = None  # 换算后数值
    normalized_unit: str | None = None
    conversion_note: str | None = None
    status: ItemStatus = ItemStatus.unknown
    status_reason: str = ""
    conflicts: list[str] = Field(default_factory=list)
    image_box: ImageBox | None = None


class ReportIn(BaseModel):
    report_type: str = "auto"  # urinalysis / uacr / auto
    test_date: str | None = None  # YYYY-MM-DD
    hospital: str | None = None  # 可选；服务端不保存
    items: list[LabItemIn]


class HistoryReport(BaseModel):
    """本地历史的摘要（用于趋势类规则），只含日期与指标。"""

    test_date: str
    items: list[LabItemIn]


class AnalyzeRequest(BaseModel):
    report: ReportIn
    answers: dict[str, Any] = Field(default_factory=dict)
    history: list[HistoryReport] = Field(default_factory=list)


class Level(str, Enum):
    red = "red"
    yellow = "yellow"
    green = "green"
    unknown = "unknown"


class RuleHit(BaseModel):
    rule_id: str
    title: str
    level: Level
    priority: int
    summary: str
    detail: str
    doctor_questions: list[str] = Field(default_factory=list)
    evidence_ids: list[str] = Field(default_factory=list)
    related_items: list[str] = Field(default_factory=list)
    review_status: str
    is_test_rule: bool = True
    urgent: bool = False


class NotEvaluable(BaseModel):
    rule_id: str
    title: str
    missing: list[str]
    note: str
