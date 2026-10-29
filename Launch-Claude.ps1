# Clauder — запуск Claude Code: обновления, режим, plugins/skills, рабочая папка.
$ErrorActionPreference = 'Continue'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = "-STA -NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process -FilePath $exe -ArgumentList $arg | Out-Null
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$npmBin = Join-Path $env:APPDATA 'npm'
if (Test-Path -LiteralPath $npmBin) {
    $env:Path = "$npmBin;$env:Path"
}

$statePath = Join-Path $PSScriptRoot 'launcher-state.json'
$host.UI.RawUI.WindowTitle = 'Claude Code'

function Read-State {
    $defaults = [ordered]@{
        permissionMode        = 'auto'
        loadPluginsAndSkills  = $true
        workingDirectory      = [Environment]::GetFolderPath('MyDocuments')
    }
    if (-not (Test-Path -LiteralPath $statePath)) {
        return [pscustomobject]$defaults
    }
    try {
        $saved = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.permissionMode -notin @('auto', 'skip')) { $saved.permissionMode = 'auto' }
        if ($null -eq $saved.loadPluginsAndSkills) { $saved.loadPluginsAndSkills = $true }
        if ([string]::IsNullOrWhiteSpace($saved.workingDirectory)) {
            $saved.workingDirectory = $defaults.workingDirectory
        }
        return $saved
    } catch {
        return [pscustomobject]$defaults
    }
}

function Save-State($state) {
    $json = $state | ConvertTo-Json
    [System.IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding $true))
}

function Get-ClaudeExe {
    $candidates = @()
    $cmd = Get-Command claude.cmd -ErrorAction SilentlyContinue
    if ($cmd) {
        $candidates += (Join-Path (Split-Path -Parent $cmd.Source) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe')
    }
    $candidates += (Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe')
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )
    $output = New-Object System.Collections.Generic.List[string]
    & $File @Arguments 2>&1 | ForEach-Object {
        $line = "$_"
        Write-Host $line
        $output.Add($line)
    }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Lines    = $output
    }
}

function Get-InstalledPlugins {
    $raw = & $script:claudeExe plugin list --json 2>$null | Out-String
    $start = $raw.IndexOf('[')
    if ($start -lt 0) { return @() }
    $end = $raw.LastIndexOf(']')
    if ($end -lt $start) { return @() }
    try {
        $parsed = $raw.Substring($start, $end - $start + 1) | ConvertFrom-Json
        return @($parsed | Where-Object { $_.id })
    } catch {
        return @()
    }
}

function Update-ClaudeAndPlugins {
    $notes = New-Object System.Collections.Generic.List[string]
    Write-Host ''
    Write-Host '=== Claude Code: проверка и установка обновлений ===' -ForegroundColor Cyan
    $app = Invoke-NativeCapture $script:claudeExe update
    if ($app.ExitCode -eq 0) {
        $notes.Add('Claude Code: проверка обновлений завершена.')
    } else {
        $notes.Add("Claude Code: обновление завершилось с кодом $($app.ExitCode). Запуск всё равно доступен.")
    }
    $tail = @($app.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 4)
    foreach ($line in $tail) { $notes.Add("  $line") }

    Write-Host ''
    Write-Host '=== Plugins: проверка и установка обновлений ===' -ForegroundColor Cyan
    $plugins = @(Get-InstalledPlugins)
    if ($plugins.Count -eq 0) {
        $notes.Add('Plugins: установленных не найдено.')
        return ($notes -join [Environment]::NewLine)
    }

    $updated = 0
    $failed = 0
    $current = 0
    foreach ($plugin in $plugins) {
        $current++
        $scope = 'user'
        if ($plugin.scope) { $scope = [string]$plugin.scope }
        Write-Host ("[{0}/{1}] {2}" -f $current, $plugins.Count, $plugin.id) -ForegroundColor DarkCyan
        $result = Invoke-NativeCapture $script:claudeExe plugin update $plugin.id -y --scope $scope
        if ($result.ExitCode -eq 0) {
            $updated++
        } else {
            $failed++
            $notes.Add("  ошибка: $($plugin.id) (код $($result.ExitCode))")
        }
    }
    $notes.Add("Plugins: проверено $($plugins.Count), без ошибки $updated, с ошибкой $failed.")
    $notes.Add('Skills из установленных plugins обновляются вместе с plugins. Отдельного обновления локальных skills нет.')
    return ($notes -join [Environment]::NewLine)
}

$script:claudeExe = Get-ClaudeExe
if (-not $script:claudeExe) {
    [System.Windows.Forms.MessageBox]::Show(
        "Claude Code не найден.`nОжидался claude.exe рядом с npm-командой claude (обычно $npmBin).",
        'Claude Code',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

$script:chosen = $null

$updateReport = Update-ClaudeAndPlugins
$state = Read-State

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Code'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(680, 560)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$header = New-Object System.Windows.Forms.Label
$header.Text = 'Обновления проверены. Выберите режим, набор расширений и рабочую папку.'
$header.Location = New-Object System.Drawing.Point(16, 14)
$header.Size = New-Object System.Drawing.Size(648, 24)
$form.Controls.Add($header)

$status = New-Object System.Windows.Forms.TextBox
$status.Location = New-Object System.Drawing.Point(16, 44)
$status.Size = New-Object System.Drawing.Size(648, 150)
$status.Multiline = $true
$status.ReadOnly = $true
$status.ScrollBars = 'Vertical'
$status.Text = $updateReport
$form.Controls.Add($status)

$modeBox = New-Object System.Windows.Forms.GroupBox
$modeBox.Text = 'Режим разрешений'
$modeBox.Location = New-Object System.Drawing.Point(16, 206)
$modeBox.Size = New-Object System.Drawing.Size(648, 96)
$form.Controls.Add($modeBox)

$radioAuto = New-Object System.Windows.Forms.RadioButton
$radioAuto.Text = 'Auto — режим permission-mode auto'
$radioAuto.Location = New-Object System.Drawing.Point(16, 28)
$radioAuto.Size = New-Object System.Drawing.Size(610, 24)
$radioAuto.Checked = ($state.permissionMode -ne 'skip')
$modeBox.Controls.Add($radioAuto)

$script:radioSkip = New-Object System.Windows.Forms.RadioButton
$script:radioSkip.Text = 'Dangerously skip permissions — без проверок разрешений'
$script:radioSkip.Location = New-Object System.Drawing.Point(16, 58)
$script:radioSkip.Size = New-Object System.Drawing.Size(610, 24)
$script:radioSkip.Checked = ($state.permissionMode -eq 'skip')
$modeBox.Controls.Add($script:radioSkip)

$extBox = New-Object System.Windows.Forms.GroupBox
$extBox.Text = 'Plugins и skills'
$extBox.Location = New-Object System.Drawing.Point(16, 312)
$extBox.Size = New-Object System.Drawing.Size(648, 100)
$form.Controls.Add($extBox)

$script:radioWith = New-Object System.Windows.Forms.RadioButton
$script:radioWith.Text = 'Со всеми установленными plugins и skills'
$script:radioWith.Location = New-Object System.Drawing.Point(16, 28)
$script:radioWith.Size = New-Object System.Drawing.Size(610, 24)
$script:radioWith.Checked = [bool]$state.loadPluginsAndSkills
$extBox.Controls.Add($script:radioWith)

$radioWithout = New-Object System.Windows.Forms.RadioButton
$radioWithout.Text = 'Без plugins и skills (safe mode: также без hooks, MCP и CLAUDE.md)'
$radioWithout.Location = New-Object System.Drawing.Point(16, 58)
$radioWithout.Size = New-Object System.Drawing.Size(610, 28)
$radioWithout.Checked = -not [bool]$state.loadPluginsAndSkills
$extBox.Controls.Add($radioWithout)

$dirLabel = New-Object System.Windows.Forms.Label
$dirLabel.Text = 'Рабочая папка'
$dirLabel.Location = New-Object System.Drawing.Point(16, 424)
$dirLabel.Size = New-Object System.Drawing.Size(200, 22)
$form.Controls.Add($dirLabel)

$script:dirBox = New-Object System.Windows.Forms.TextBox
$script:dirBox.Location = New-Object System.Drawing.Point(16, 448)
$script:dirBox.Size = New-Object System.Drawing.Size(520, 28)
$script:dirBox.Text = [string]$state.workingDirectory
$form.Controls.Add($script:dirBox)

$browse = New-Object System.Windows.Forms.Button
$browse.Text = 'Обзор...'
$browse.Location = New-Object System.Drawing.Point(544, 446)
$browse.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($browse)

$launch = New-Object System.Windows.Forms.Button
$launch.Text = 'Запустить'
$launch.Location = New-Object System.Drawing.Point(424, 502)
$launch.Size = New-Object System.Drawing.Size(140, 36)
$form.Controls.Add($launch)
$form.AcceptButton = $launch

$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Отмена'
$cancel.Location = New-Object System.Drawing.Point(572, 502)
$cancel.Size = New-Object System.Drawing.Size(92, 36)
$cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancel)
$form.CancelButton = $cancel

$browse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Выберите папку, в которой будет работать Claude Code'
    $dialog.ShowNewFolderButton = $true
    if (Test-Path -LiteralPath $script:dirBox.Text) {
        $dialog.SelectedPath = $script:dirBox.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:dirBox.Text = $dialog.SelectedPath
    }
})

$launch.Add_Click({
    $dir = $script:dirBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($dir)) {
        [System.Windows.Forms.MessageBox]::Show('Укажите рабочую папку.', 'Claude Code') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Папки нет. Создать её?`n$dir",
            'Claude Code',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show('Нужна папка, а не файл.', 'Claude Code') | Out-Null
        return
    }

    $script:chosen = [pscustomobject]@{
        permissionMode       = $(if ($script:radioSkip.Checked) { 'skip' } else { 'auto' })
        loadPluginsAndSkills = [bool]$script:radioWith.Checked
        workingDirectory     = $dir
    }
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})

$result = $form.ShowDialog()
if ($result -ne [System.Windows.Forms.DialogResult]::OK -or -not $script:chosen) {
    exit 0
}

Save-State $script:chosen
Set-Location -LiteralPath $script:chosen.workingDirectory

$claudeArgs = @()
if ($script:chosen.permissionMode -eq 'skip') {
    $claudeArgs += '--dangerously-skip-permissions'
} else {
    $claudeArgs += '--permission-mode'
    $claudeArgs += 'auto'
}
if (-not $script:chosen.loadPluginsAndSkills) {
    $claudeArgs += '--safe-mode'
    $claudeArgs += '--disable-slash-commands'
}

Write-Host ''
Write-Host ("Папка: {0}" -f $script:chosen.workingDirectory) -ForegroundColor Green
Write-Host ("Команда: claude {0}" -f ($claudeArgs -join ' ')) -ForegroundColor Green
Write-Host ''

& $script:claudeExe @claudeArgs
Write-Host ''
Write-Host "Claude Code завершился с кодом $LASTEXITCODE. Это окно можно закрыть." -ForegroundColor Yellow
