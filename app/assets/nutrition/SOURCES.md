# 餐饮估算资料

- USDA FoodData Central，FNDDS 2021–2023，2024-10 发布。每项保存 FDC ID、原文描述、每 100 g 总碳水（营养素 1005）及总糖（营养素 2000）。来源为官方 [下载页](https://fdc.nal.usda.gov/download-datasets/)。食物克重由用户确认。混合餐食的真实配方和标签可能与数据库样品不同。
- 中式食物辨识模型 `food_cn-c9a5f4f7.onnx`（59 类，标签 `labels_cn.txt`，cnXXX 为 CNFOOD-241 类别编号）：以 torchvision ImageNet 预训练 MobileNet V2（冻结）为特征提取器，在 [CNFOOD-241](https://data.mendeley.com/datasets/fspyss5zbb/1)（DOI 10.17632/fspyss5zbb.1，**CC BY-NC 3.0，只能非商业使用**；部分照片来自 ChineseFoodNet）上训练新的分类层（1280→512→59）。训练 56,410 张（完整训练集＋验证集 70%），验证集保留 30%（1,986 张）测试：top-1 74%、top-3 91%（三种分类层在同一测试集上比较后选出，数字可能略为乐观）。APP 在最高机率 ≥0.2 时给前三名候选：测试照片 94% 会给候选，其中前三名含正确答案 93%。ONNX SHA-256 为 `c9a5f4f77ced65b65b8847e3cb92e6c88c3824b6536203165837d25bb600644d`。训练与评估程序见 `tools/food_cn/`。若要商业使用，须改用其他授权资料重新训练。
- 中式菜色的营养条目：`food_reference.json` 中带 `cnXXX` 标签的 59 项，取自上述 USDA FNDDS 最接近的条目（对照表 `tools/food_cn/cn_food_reference.json`）；42 项标为近似（`approx`），APP 显示「近似」。照片候选须由用户确认后才估算碳水。
- 原 Food-101 MobileNet V2（Apache-2.0，ONNX SHA-256 `8021c00d…`）已由上述模型取代，原 24 项西式食物保留供手动选择。
