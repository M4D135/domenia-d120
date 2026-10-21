# Runs the capture mode of Domenia 2 inside the Domenia VM (docs/CAPTURE.md), then prints capture.log.
# Default executable: the published pack (embedded WebView2), else the Release build, else the Debug build.
# Simulation only: Domenia refuses --capture in directory mode (real data would end up in the images).
param(
    [string]$Output = 'C:\DomeniaDev\captures',
    [string]$Exe = ''
)
$ErrorActionPreference = 'Stop'
# Through SSH the console keeps the OEM code page: UTF-8 keeps the accents of capture.log and of this script readable.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $OutputEncoding = [Console]::OutputEncoding
} catch {
    Write-Warning ('Encodage UTF-8 de la console non appliqué : ' + $_.Exception.GetType().Name + '.')
}
$root = 'C:\DomeniaDev\src\v2'
if (-not $Exe) {
    $candidates = @(
        'C:\DomeniaDev\out\Domenia\Domenia.exe',
        (Join-Path $root 'src\Domenia.App\bin\x64\Release\net10.0-windows\win-x64\Domenia.exe'),
        (Join-Path $root 'src\Domenia.App\bin\x64\Debug\net10.0-windows\win-x64\Domenia.exe'))
    $Exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Exe) { throw 'Aucun Domenia.exe : lancer avant tools\build-vm.ps1 (avec -Publish pour le pack).' }
}
# Start-Process joins the arguments as they are: the folder is quoted here. Before a closing quote, backslashes are
# doubled (C:\x\ would otherwise end in an escaped quote and reach Domenia as C:\x").
$arguments = @('--simulation', '--capture', ('"{0}"' -f ($Output -replace '(\\+)$', '$1$1')))
"Lancement : $Exe $($arguments -join ' ')"
$process = Start-Process -FilePath $Exe -ArgumentList $arguments -PassThru
# Reading the handle now keeps the exit code available once the process has ended.
$null = $process.Handle
# Domenia ends by itself (watchdog included); this bound only protects the SSH session.
if (-not $process.WaitForExit(330000)) {
    Stop-Process -Id $process.Id -Force
    'Domenia toujours actif après le délai : processus arrêté.'
    exit 2
}
$log = Join-Path $Output 'capture.log'
if (Test-Path $log) { Get-Content -Encoding UTF8 $log } else { 'Aucun capture.log : voir le journal technique (%LOCALAPPDATA%\Domenia\logs\domenia.log).' }
"Code de sortie : $($process.ExitCode)"
exit $process.ExitCode
