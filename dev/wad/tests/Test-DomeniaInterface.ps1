#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'maintenance\Preview-DomeniaUi.ps1') -Verify -ReportPath $ReportPath -Quiet:$Quiet
