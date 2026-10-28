"""正式知识库（kb.yaml，由 Excel 导入）与占位知识一起检索，正式知识优先。"""
from app import knowledge


def test_formal_kb_loaded_and_ranked_first(tmp_path, monkeypatch):
    formal = tmp_path / "kb.yaml"
    formal.write_text(
        "entries:\n"
        "- {id: kb-uacr-901, title: 正式条目, codes: [UACR], keywords: [肾], source: 测试指南（p.1）,"
        " source_version: '2021', review_status: 已审核, text: 正式知识内容}\n", encoding="utf-8")
    monkeypatch.setattr(knowledge, "KB_FILES", [formal, knowledge.KB_DIR / "kb_test.yaml"])
    knowledge.load_kb.cache_clear()
    try:
        hits = knowledge.search(codes=["UACR"])
        assert hits[0].id == "kb-uacr-901"           # 同样相关时，正式知识排在占位知识前
        assert any(h.id == "kb-test-uacr-001" for h in hits)  # 占位知识仍可检索
        assert knowledge.get("kb-uacr-901").source == "测试指南（p.1）"
        # 问「是什么」时，标题为「…是什么」的条目更相关，排在前面
        assert knowledge.search("UACR是什么", codes=["UACR"])[0].id == "kb-test-uacr-001"
    finally:
        knowledge.load_kb.cache_clear()


def test_missing_formal_kb_is_fine(tmp_path, monkeypatch):
    monkeypatch.setattr(knowledge, "KB_FILES", [tmp_path / "kb.yaml", knowledge.KB_DIR / "kb_test.yaml"])
    knowledge.load_kb.cache_clear()
    try:
        assert knowledge.search(codes=["KET"])[0].id == "kb-test-ket-001"
    finally:
        knowledge.load_kb.cache_clear()