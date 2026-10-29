# 用 PowerPoint 把 pptx 导出为 PDF（比赛要求答辩 PPT 以 PDF 提交）。32 位 PowerShell 运行。
param([string]$Pptx, [string]$Pdf)
$app = New-Object -ComObject PowerPoint.Application
try {
    $p = $app.Presentations.Open($Pptx, $true, $false, $false)  # 只读、不显示窗口
    $p.SaveAs($Pdf, 32)  # ppSaveAsPDF
    $p.Close()
    "exported"
} finally { $app.Quit() }
