// 端侧数据模型。坐标统一为「旋转/裁剪后正向图像」上的归一化坐标（0~1）。

/// 归一化矩形框（相对正向报告图像）。
class NormBox {
  final int page;
  final double x, y, w, h;
  const NormBox({this.page = 1, required this.x, required this.y, required this.w, required this.h});

  double get cx => x + w / 2;
  double get cy => y + h / 2;
  double get right => x + w;
  double get bottom => y + h;

  factory NormBox.fromJson(Map<String, dynamic> j) => NormBox(
        page: (j['page'] as num?)?.toInt() ?? 1,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num).toDouble(),
        h: (j['h'] as num).toDouble(),
      );
  Map<String, dynamic> toJson() => {'page': page, 'x': x, 'y': y, 'w': w, 'h': h};

  NormBox union(NormBox o) {
    final x0 = x < o.x ? x : o.x, y0 = y < o.y ? y : o.y;
    final x1 = right > o.right ? right : o.right, y1 = bottom > o.bottom ? bottom : o.bottom;
    return NormBox(page: page, x: x0, y: y0, w: x1 - x0, h: y1 - y0);
  }
}

/// OCR 识别出的一行文本。
class OcrLine {
  final String text;
  final double confidence;
  final NormBox box;
  const OcrLine({required this.text, required this.confidence, required this.box});

  factory OcrLine.fromJson(Map<String, dynamic> j) => OcrLine(
        text: j['text'] as String,
        confidence: (j['confidence'] as num).toDouble(),
        box: NormBox.fromJson(j['box'] as Map<String, dynamic>),
      );
}

enum ReviewStatus { autoAccepted, confirmed, unknown, excluded, needsConfirmation }

extension ReviewStatusApi on ReviewStatus {
  String get api => const {
        ReviewStatus.autoAccepted: 'auto_accepted',
        ReviewStatus.confirmed: 'confirmed',
        ReviewStatus.unknown: 'unknown',
        ReviewStatus.excluded: 'excluded',
        ReviewStatus.needsConfirmation: 'needs_confirmation',
      }[this]!;

  static ReviewStatus parse(String s) =>
      ReviewStatus.values.firstWhere((e) => e.api == s, orElse: () => ReviewStatus.needsConfirmation);
}

/// 报告中的一个检验项目（端侧结构化结果）。
class LabItem {
  final String? code;
  final String label;
  String? value;
  final String? unit;
  final String? reference;
  final String? flag;
  final double confidence;
  ReviewStatus status;
  final NormBox? valueBox;
  final NormBox? rowBox;
  final List<String> candidates;
  final List<String> reviewReasons;

  LabItem({
    required this.code,
    required this.label,
    required this.value,
    this.unit,
    this.reference,
    this.flag,
    required this.confidence,
    required this.status,
    this.valueBox,
    this.rowBox,
    this.candidates = const [],
    this.reviewReasons = const [],
  });

  bool get needsReview => status == ReviewStatus.needsConfirmation;

  /// 发往后端的最小化结构化数据：不含图像，不含医院与姓名。
  Map<String, dynamic> toApi() => {
        if (code != null) 'code': code,
        'original_label': label,
        'raw_value': value,
        'unit': unit,
        'reference_text': reference,
        'abnormal_flag': flag,
        'ocr_confidence': confidence,
        'review_status': status.api,
      };

  Map<String, dynamic> toJson() => {
        ...toApi(),
        'value_box': valueBox?.toJson(),
        'row_box': rowBox?.toJson(),
        'candidates': candidates,
        'review_reasons': reviewReasons,
      };

  factory LabItem.fromJson(Map<String, dynamic> j) => LabItem(
        code: j['code'] as String?,
        label: j['original_label'] as String,
        value: j['raw_value'] as String?,
        unit: j['unit'] as String?,
        reference: j['reference_text'] as String?,
        flag: j['abnormal_flag'] as String?,
        confidence: (j['ocr_confidence'] as num?)?.toDouble() ?? 0,
        status: ReviewStatusApi.parse(j['review_status'] as String),
        valueBox: j['value_box'] == null ? null : NormBox.fromJson(j['value_box'] as Map<String, dynamic>),
        rowBox: j['row_box'] == null ? null : NormBox.fromJson(j['row_box'] as Map<String, dynamic>),
        candidates: (j['candidates'] as List?)?.cast<String>() ?? const [],
        reviewReasons: (j['review_reasons'] as List?)?.cast<String>() ?? const [],
      );
}

/// 解析后的报告。
class ParsedReport {
  final String reportType; // urinalysis / uacr / urinalysis+uacr / unsupported
  final String? testDate;
  final List<LabItem> items;
  final List<String> otherLabels; // 识别到但不在首期范围的项目
  const ParsedReport({required this.reportType, this.testDate, required this.items, this.otherLabels = const []});

  bool get supported => reportType != 'unsupported';
  List<LabItem> get pendingReview => items.where((i) => i.needsReview).toList();
}
