"""读取 Word 导出的 PDF，找出各「材料」起始页，写入 pages.json，并给 PDF 添加书签。
用法：python finish_evidence.py <pdf> <pages.json> [--bookmarks]
"""
import json
import sys
from pathlib import Path

import pymupdf

sys.stdout.reconfigure(encoding="utf-8")
pdf, pages_json = Path(sys.argv[1]), Path(sys.argv[2])
keys = ["材料一", "材料二", "材料三", "材料四", "材料五", "材料六", "材料七", "材料八"]
doc = pymupdf.open(pdf)
pages = {}
for k in keys:
    for i in range(2, len(doc)):  # 跳过封面与目录
        if (k + "  ") in doc[i].get_text():
            pages[k] = i + 1
            break
print("起始页", pages, "共", len(doc), "页")
if "--bookmarks" in sys.argv:
    toc = [[1, "封面与说明", 1], [1, "目录", 2]] + [[1, f"{k}  " + (doc[pages[k] - 1].get_text().split(k + "  ")[1].split("\n")[0].strip()), pages[k]] for k in keys if k in pages]
    doc.set_toc(toc)
    out = pdf.with_suffix(".tmp.pdf")
    doc.save(out, deflate=True)
    doc.close()
    out.replace(pdf)
    print("已添加书签")
else:
    pages_json.write_text(json.dumps(pages, ensure_ascii=False), encoding="utf-8")
