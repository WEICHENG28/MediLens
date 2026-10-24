"""知识检索（占位实现：按指标代码与关键词打分）。

检索结果只用于解释既有规则，不能决定风险等级。检索不到时明确返回空，由调用方说明「暂无可核验资料」。
正式知识库规模确定后，可替换为向量检索（FAISS/pgvector），接口保持不变。
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

import yaml
from pydantic import BaseModel

KB_PATH = Path(__file__).parent / "knowledge_base" / "kb_test.yaml"


class Citation(BaseModel):
    id: str
    title: str
    source: str
    source_version: str
    review_status: str
    text: str


@lru_cache
def load_kb() -> dict:
    with open(KB_PATH, encoding="utf-8") as f:
        return yaml.safe_load(f)


def get(entry_id: str) -> Citation | None:
    for e in load_kb()["entries"]:
        if e["id"] == entry_id:
            return _cite(e)
    return None


def _cite(e: dict) -> Citation:
    return Citation(**{k: e[k] for k in Citation.model_fields})


def search(query: str = "", codes: list[str] | None = None, limit: int = 3) -> list[Citation]:
    codes = codes or []
    q = query.upper()
    scored = []
    for e in load_kb()["entries"]:
        score = 2 * len(set(codes) & set(e["codes"]))
        score += sum(1 for kw in e["keywords"] if kw.upper() in q)
        if score > 0:
            scored.append((score, e))
    scored.sort(key=lambda x: -x[0])
    return [_cite(e) for _, e in scored[:limit]]
