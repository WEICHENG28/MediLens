# 用 Word 统计正文字数（「一、项目概述」至「七、附录」之前，不含附录）。32 位 PowerShell 运行。
param([string]$Docx)
$word = New-Object -ComObject Word.Application
try {
    $doc = $word.Documents.Open($Docx, $false, $true)
    $start = $null; $end = $null
    foreach ($p in $doc.Paragraphs) {
        $t = $p.Range.Text.Trim()
        if ($t -eq "一、项目概述" -and $p.OutlineLevel -eq 1) { $start = $p.Range.Start }
        if ($t -eq "七、附录" -and $p.OutlineLevel -eq 1) { $end = $p.Range.Start }
    }
    $r = $doc.Range($start, $end)
    "正文字数（Word 统计）：" + $r.ComputeStatistics(0)
    $doc.Close($false)
} finally { $word.Quit() }
