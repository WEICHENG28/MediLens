# 端侧 OCR 模型说明

| 文件 | 用途 | SHA-256 |
|---|---|---|
| det.onnx | PP-OCRv5 mobile 文本检测 | 4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae |
| rec.onnx | PP-OCRv5 mobile 文本识别（18385 类） | 5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5 |
| ppocrv5_dict.txt | 识别字典（18383 字符） | — |

- 模型元数据显示为 PaddlePaddle（PIR）经 paddle2onnx 转换的 ONNX 模型；PaddleOCR 采用 Apache-2.0 许可。
- ⚠️ **下载来源未记录**：模型由上一轮开发会话下载，该会话记录丢失，具体下载地址待复核。上线前需从 PaddleOCR 官方渠道重新获取、核对许可证与哈希。
- 模型随 APP 打包，运行时不联网下载；原始报告图像只在本机识别。
- 已用 `tools/ocr_reference.py` 在合成报告上验证可正确识别（见 docs/开发进展.md）。
