# 餐饮估算资料

- USDA FoodData Central，FNDDS 2021–2023，2024-10 发布。每项保存 FDC ID、原文描述、每 100 g 总碳水（营养素 1005）及总糖（营养素 2000）。来源为官方 [下载页](https://fdc.nal.usda.gov/download-datasets/)。食物克重由用户确认。混合餐食的真实配方和标签可能与数据库样品不同。
- Food-101 MobileNet V2，Apache-2.0。[训练权重](https://huggingface.co/AlexKoff88/mobilenet_v2_food101/tree/7d05d3878ee7f2aad7ad159018a8e5fdb4953d41) SHA-256 为 `42cd5d9988f0830588b3be5107197c9b622c9b73426377975c07e8b24e346680`。[训练代码](https://github.com/AlexKoff88/mobilenetv2_food101)。使用 epoch 27 权重，去掉 `module.` 前缀后载入 torchvision MobileNet V2 的 101 类模型，按 eval 模式重新导出 ONNX opset 17。ONNX SHA-256 为 `8021c00db96c89fa704faca0ed079a58ee3cc9b7806a565a55e709bafe4acc1f`。类别为 torchvision Food101 排序。照片候选须由用户确认后才能与 USDA 条目关联。
