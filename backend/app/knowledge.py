"""知识检索（按指标代码与关键词打分）。

数据来源（依序加载）：
- knowledge_base/kb.yaml       正式知识库：由 tools/kb_import.py 从组员填写的 Excel 导入（存在时加载）
- knowledge_base/kb_test.yaml  占位知识：开发团队自编，非指南原文
先按相关程度（指标代码、关键词、标题字词重合），同样相关时正式知识优先于占位知识、已审核优先。检索结果只用于解释既有规则，不能决定风险等级；检索不到时返回空，
由调用方说明「暂无可核验资料」。正式知识库规模扩大后可替换为向量检索，接口保持不变。
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

import yaml
from pydantic import BaseModel

KB_DIR = Path(__file__).parent / "knowledge_base"
KB_FILES = [KB_DIR / "kb.yaml", KB_DIR / "kb_test.yaml"]  # 正式在前
KB_PATH = KB_DIR / "kb_test.yaml"  # 兼容旧引用


class Citation(BaseModel):
    id: str
    title: str
    source: str
    source_version: str
    review_status: str
    text: str


@lru_cache
def load_kb() -> dict:
    entries: list[dict] = []
    for i, path in enumerate(KB_FILES):
        if path.exists():
            data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            for e in data.get("entries", []):
                entries.append({**e, "_formal": path.name == "kb.yaml", "_order": len(entries)})
    return {"entries": entries}


def get(entry_id: str) -> Citation | None:
    for e in load_kb()["entries"]:
        if e["id"] == entry_id:
            return _cite(e)
    return None


def _cite(e: dict) -> Citation:
    return Citation(**{k: str(e[k]) for k in Citation.model_fields})


def _bigrams(text: str) -> set[str]:
    t = "".join(ch for ch in text.upper() if ch.isalnum())
    return {t[i:i + 2] for i in range(len(t) - 1)}


def search(query: str = "", codes: list[str] | None = None, limit: int = 3) -> list[Citation]:
    """打分：指标代码相同 +2；关键词出现在问题中 +1；问题与标题每有一组相同的两字 +0.5。"""
    codes = codes or []
    q = query.upper()
    qgrams = _bigrams(query)
    scored = []
    for e in load_kb()["entries"]:
        score = 2 * len(set(codes) & set(e["codes"]))
        score += sum(1 for kw in e.get("keywords", []) if kw and kw.upper() in q)
        if score > 0:
            score += 0.5 * len(qgrams & _bigrams(e["title"]))
            reviewed = e.get("review_status") in ("已审核", "reviewed")
            # 先比相关程度；同样相关时，正式知识优先于占位知识，其次已审核优先
            scored.append(((score, e["_formal"], reviewed, -e["_order"]), e))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [_cite(e) for _, e in scored[:limit]]
