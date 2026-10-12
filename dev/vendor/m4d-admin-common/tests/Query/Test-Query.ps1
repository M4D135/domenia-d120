# Pure tests, no network, AD, WPF or VM. Windows PS 5.1 or PowerShell 7.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Add-Type -Path @((Join-Path $root 'src/Query/QueryEngine.cs'), (Join-Path $PSScriptRoot 'QueryTests.cs'))
$count = [QueryTests]::Run()
Write-Output ("PASS Query: {0} assertions ({1}, {2})" -f $count, $PSVersionTable.PSVersion, [Environment]::OSVersion)
