# Создаёт или обновляет ярлык Claude Code на рабочем столе.
$ErrorActionPreference = 'Stop'

$launchScript = Join-Path $PSScriptRoot 'Launch-Claude.ps1'
if (-not (Test-Path -LiteralPath $launchScript)) {
    throw "Не найден $launchScript"
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'Claude Code.lnk'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = "-STA -NoExit -NoProfile -ExecutionPolicy Bypass -File `"$launchScript`""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.WindowStyle = 1
$shortcut.Description = 'Claude Code: обновления, режим auto или skip permissions, plugins и рабочая папка'
$shortcut.IconLocation = "$powershell,0"
$shortcut.Save()

Write-Output $shortcutPath
