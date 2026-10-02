#requires -Version 5.1
[CmdletBinding()]
param([switch]$Console)
& (Join-Path $PSScriptRoot 'Domenia.exe') --diagnostic
exit $LASTEXITCODE
