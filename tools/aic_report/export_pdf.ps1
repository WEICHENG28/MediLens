# 用 Word 更新目录与域、统计字数并导出 PDF。需在 32 位 PowerShell 中运行（本机 Office 为 32 位）：
#   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File export_pdf.ps1 -Docx <docx> -Pdf <pdf>
param([string]$Docx, [string]$Pdf)
$word = New-Object -ComObject Word.Application
$word.Visible = $false
try {
    $doc = $word.Documents.Open($Docx)
    foreach ($toc in $doc.TablesOfContents) { $toc.Update() }
    $doc.Fields.Update() | Out-Null
    $doc.Save()
    # 字数（wdStatisticWords = 0）与页数（wdStatisticPages = 2）
    "全文字数（Word 统计）：" + $doc.ComputeStatistics(0)
    "页数：" + $doc.ComputeStatistics(2)
    $doc.ExportAsFixedFormat($Pdf, 17)  # wdExportFormatPDF
    $doc.Close()
    "已导出 PDF：$Pdf"
} finally {
    $word.Quit()
}
