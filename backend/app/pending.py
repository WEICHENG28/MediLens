"""已确认但本轮「待实现」的功能接口。

保留路由、数据结构与候选服务，统一返回 HTTP 501，避免客户端误以为功能可用。
候选服务均为中国大陆可直接访问的厂商，接入前需查阅官方文档并实测。
"""
from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel

router = APIRouter(prefix="/api/v1")

VOICE_STATES = ["voice_off", "connecting", "listening", "thinking", "speaking", "interrupted", "reconnecting", "failed"]


def _pending(feature: str, providers: list[str], note: str = "") -> JSONResponse:
    return JSONResponse(
        status_code=501,
        content={"status": "not_implemented", "feature": feature, "message": f"{feature}：待实现",
                 "planned_providers": providers, "note": note},
    )


@router.get("/voice/states")
def voice_states() -> dict:
    """实时语音状态机定义（客户端已按此实现入口与状态展示）。"""
    return {"states": VOICE_STATES, "barge_in": True, "status": "not_implemented"}


@router.post("/voice/session")
def voice_session():
    return _pending("实时语音对话（可打断）", ["讯飞开放平台", "阿里云智能语音交互"],
                    "打断时须保留结构化数据、当前问题与安全提示；重要提示同步显示文字")


@router.post("/medication/recognize")
def medication_recognize():
    return _pending("药盒/处方辅助识别", ["端侧 OCR + 药品名称字典", "百度/腾讯云 OCR（需授权）"],
                    "识别结果需用户确认；不确定时不猜药名；不给出停药/换药/剂量建议")


class CloudOcrConsent(BaseModel):
    consent_record_id: str | None = None


@router.post("/ocr/cloud")
def cloud_ocr(_: CloudOcrConsent | None = None):
    return _pending("云端 OCR（仅注册用户，需单独授权后上传原图）", ["百度智能云 OCR", "腾讯云 OCR"])


@router.post("/auth/register")
def register():
    return _pending("注册", [], "注册方式（手机号/邮箱）待产品确认")


@router.post("/auth/login")
def login():
    return _pending("登录", [])


@router.post("/backup/upload")
def backup_upload():
    return _pending("可选云端备份（按类别：报告/结构化指标/对话）", ["阿里云 OSS", "腾讯云 COS"],
                    "备份/恢复 ≠ 实时多端同步；未选中的类别不得上传")


@router.post("/backup/restore")
def backup_restore():
    return _pending("云端备份恢复", ["阿里云 OSS", "腾讯云 COS"])
