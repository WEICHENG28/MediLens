# 只用 Word 更新目录与页码并保存（不导出 PDF）。32 位 PowerShell 运行。
param([string]$Docx)
$word = New-Object -ComObject Word.Application
try {
    $doc = $word.Documents.Open($Docx)
    foreach ($toc in $doc.TablesOfContents) { $toc.Update() }
    $doc.Fields.Update() | Out-Null
    $doc.Save()
    $doc.Close()
    "updated"
} finally { $word.Quit() }
