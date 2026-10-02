# Native syntax validation only. No domain access and no application bootstrap.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourceRoot,
      [Parameter(Mandatory=$true)][string]$ReportPath,
      [switch]$RequireWindows51)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($SourceRoot)
$started = [DateTime]::UtcNow.ToString('o')
$edition = if ($PSVersionTable.ContainsKey('PSEdition')) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
$isNativeWindows51 = ($env:OS -eq 'Windows_NT' -and $edition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
$rows = New-Object 'System.Collections.Generic.List[object]'
$failures = 0
$paths = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.ps1','.psm1','.psd1' })
if ($paths.Count -eq 0) { throw 'No PowerShell source found.' }
foreach ($file in $paths) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    $detail = @($errors | ForEach-Object { [pscustomobject]@{ ErrorId=$_.ErrorId;Line=$_.Extent.StartLineNumber;Message=$_.Message } })
    if ($detail.Count -gt 0) { $failures++ }
    $rows.Add([pscustomobject]@{ File=$file.FullName.Substring($root.Length).TrimStart('\','/');Status=$(if($detail.Count){'FAIL'}else{'PASS'});SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;Errors=$detail })
}
$fixtures = @(
    @{Name='bare-command-after-or';Code='if ($false -or Test-Example) { 1 }';ExpectFailure=$true},
    @{Name='parenthesized-command-after-or';Code='if ($false -or (Test-Example)) { 1 }';ExpectFailure=$false},
    @{Name='unterminated-string';Code="Write-Output 'unfinished";ExpectFailure=$true},
    @{Name='balanced-scriptblock';Code='param($x) if ($null -ne $x) { return @($x) }';ExpectFailure=$false}
)
$fixtureRows = New-Object 'System.Collections.Generic.List[object]'
foreach($fixture in $fixtures) {
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($fixture.Code,[ref]$tokens,[ref]$errors)
    $hasError=@($errors).Count -gt 0
    $ok=$hasError -eq $fixture.ExpectFailure
    if(-not $ok){$failures++}
    $fixtureRows.Add([pscustomobject]@{Name=$fixture.Name;Status=$(if($ok){'PASS'}else{'FAIL'});Rejected=$hasError})
}
$qualifying = $isNativeWindows51 -and $failures -eq 0
$report=[ordered]@{
    Kind='NativeParser';StartedUtc=$started;EndedUtc=[DateTime]::UtcNow.ToString('o')
    Host=@{Platform=$(if($env:OS -eq 'Windows_NT'){'Windows'}else{'NonWindows'});PSEdition=$edition;PSVersion=$PSVersionTable.PSVersion.ToString()}
    Status=$(if($failures){'FAIL'}else{'PASS'});Files=$rows.ToArray();RegressionFixtures=$fixtureRows.ToArray()
    Windows51Qualification=$qualifying;WorkersExecuted=$false;WpfExecuted=$false;DomainAccessed=$false
    Limitations=@('Parser success does not execute the module loader, application or UI.','PowerShell 7 parsing is not Windows PowerShell 5.1 qualification.','Dynamic worker code requires a separate contract test.')
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if($failures -gt 0){exit 1}
if($RequireWindows51 -and -not $qualifying){exit 2}
exit 0
