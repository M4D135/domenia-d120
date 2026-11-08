param([string]$ReportPath = '')
$ErrorActionPreference = 'Stop'
$src = (Resolve-Path 'dev/wad/modules/Domenia-Live.Model.ps1').Path
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'parse errors in Domenia-Live.Model.ps1' }
$wanted = @('Get-DomeniaLiveField','ConvertTo-DomeniaLiveObservation','Get-DomeniaLiveObservationView','Test-DomeniaLiveAttemptAfter')
$found = @{}
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $fn.Name) { $found[$fn.Name] = $fn }
}
foreach ($name in $wanted) { if (-not $found.ContainsKey($name)) { throw "function $name not found" } }
foreach ($name in $wanted) { . ([scriptblock]::Create($found[$name].Extent.Text)) }

$failures = @()
$asserts = 0
function Assert-Point10([bool]$Condition, [string]$Label) {
    $script:asserts++
    if (-not $Condition) { $script:failures += $Label; Write-Host ("FAIL: " + $Label) } else { Write-Host ("ok: " + $Label) }
}

$guid = '00000000-0000-0000-0000-000000000001'
$observed = [pscustomobject]@{ Key='cn=pc-01,ou=test,dc=example,dc=invalid'; Computer='pc-01'; Guid=$guid; Outcome='Observed'; User='EXAMPLE\alice'; Source='CIM/DCOM · Win32_ComputerSystem.UserName'; Transport='CIM/DCOM'; Detail='Compte console observe.'; Presence='En ligne'; PresenceCheckedUtc='2026-10-17T08:00:00.0000000Z'; PresenceDetail='' }
$o1 = ConvertTo-DomeniaLiveObservation $observed $null '2026-10-17T08:00:00.0000000Z'
Assert-Point10 (([string]$o1.Transport) -eq 'CIM/DCOM') 'merge propague Transport du resultat'
$v1 = Get-DomeniaLiveObservationView $o1
Assert-Point10 ($v1.Detail.Contains('Transport : CIM/DCOM')) 'vue affiche le transport reellement execute'
Assert-Point10 ($v1.Detail.Contains('Source : CIM/DCOM')) 'vue affiche la source'
Assert-Point10 (([string]$v1.Transport) -eq 'CIM/DCOM') 'vue expose Transport'

$failure = [pscustomobject]@{ Key='cn=pc-01,ou=test,dc=example,dc=invalid'; Computer='pc-01'; Guid=$guid; Outcome='Unavailable'; User=''; Source=''; Transport=''; Detail='Lecture CIM/DCOM non confirmee.'; Presence='Erreur de ping'; PresenceCheckedUtc='2026-10-17T09:00:00.0000000Z'; PresenceDetail='ping KO' }
$o2 = ConvertTo-DomeniaLiveObservation $failure $o1 '2026-10-17T09:00:00.0000000Z'
$v2 = Get-DomeniaLiveObservationView $o2
Assert-Point10 ($v2.Detail.Contains('Transport : inconnu')) 'lecture echouee : transport affiche inconnu'
Assert-Point10 ($v2.Detail.Contains('Source : inconnue')) 'lecture echouee : source affichee inconnue'
Assert-Point10 (([string]$o2.LastUser) -eq 'EXAMPLE\alice') 'echec ne remplace pas le dernier compte observe'

$legacy = [pscustomobject]@{ Key='cn=pc-02,ou=test,dc=example,dc=invalid'; Computer='pc-02'; Guid='00000000-0000-0000-0000-000000000002'; Outcome='Observed'; User='EXAMPLE\bob'; Source='CIM/DCOM'; Detail='Ancienne mesure sans champ Transport.'; Presence='En ligne'; PresenceCheckedUtc='2026-10-16T08:00:00.0000000Z' }
$o3 = ConvertTo-DomeniaLiveObservation $legacy $null '2026-10-16T08:00:00.0000000Z'
$v3 = Get-DomeniaLiveObservationView $o3
Assert-Point10 ($v3.Detail.Contains('Transport : inconnu')) 'donnees anciennes sans Transport : inconnu, jamais une certitude'

$presenceOnly = [pscustomobject]@{ Key='cn=pc-01,ou=test,dc=example,dc=invalid'; Computer='pc-01'; Guid=$guid; Outcome='PresenceOnly'; Presence='En ligne'; PresenceCheckedUtc='2026-10-17T10:00:00.0000000Z'; PresenceDetail='' }
$o4 = ConvertTo-DomeniaLiveObservation $presenceOnly $o1 '2026-10-17T10:00:00.0000000Z'
Assert-Point10 (([string]$o4.Transport) -eq 'CIM/DCOM') 'ping seul conserve le transport de la derniere mesure'

$report = [ordered]@{ Suite='Point10-transport-provenance'; Environment='pwsh7 Linux, non qualifiant'; Executed=(Get-Date).ToString('o'); Total=1; Assertions=$asserts; Passed=($failures.Count -eq 0); Failed=$failures.Count; Failures=$failures }
if ($ReportPath) { $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding UTF8 }
if ($failures.Count -gt 0) { Write-Host ('FAILED ' + $failures.Count); exit 1 }
Write-Host ('PASSED: ' + $asserts + ' assertions')
