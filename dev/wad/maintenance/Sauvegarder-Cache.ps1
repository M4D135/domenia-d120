#requires -Version 5.1
<# Explicit, local snapshot. This does not bind to AD, read credentials, restore or delete the source.
   Run on a locally accessible DOMENIA SQLite file, preferably with DOMENIA closed.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory)][string]$DatabasePath)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -eq 'Core' -or -not [Environment]::Is64BitProcess){throw 'Utiliser Windows PowerShell 5.1 64 bits.'}
$script:MaintenanceDatabase=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DatabasePath).Path)
if([IO.Path]::GetExtension($script:MaintenanceDatabase) -ine '.db'){throw 'Choisir un fichier SQLite .db.'}
$core=Join-Path $PSScriptRoot '..\Domenia-Core.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){throw 'Le coeur DOMENIA ne passe pas le parseur PowerShell.'}
# P-CD-09: the SQLite reader traces a swallowed error with Write-DomeniaSwallowed (core script scope): the core's own
# trace is loaded with it. It never throws; without journal nor ring in this script, the error stays silent as before.
$wanted=@('Write-DomeniaSwallowed','Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr','Open-DomeniaDatabase','Close-DomeniaDatabase','Invoke-DomeniaDbQuery','Get-DomeniaStoreBackupDirectory','Backup-DomeniaDatabase')
$defs=New-Object 'System.Collections.Generic.List[string]'
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($name in $wanted){$matches=@($nodes|Where-Object{$_.Name -eq $name});if($matches.Count -ne 1){throw "Fonction invalide : $name"};$defs.Add($matches[0].Extent.Text)}
. ([scriptblock]::Create(($defs -join "`r`n")))
$script:WinSqliteNative=$null
function Get-DomeniaDatabasePath {return $script:MaintenanceDatabase}
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
if($PSCmdlet.ShouldProcess($script:MaintenanceDatabase,'Creer une sauvegarde SQLite coherente et verifiee dans Backups (7 copies maximum)')){
    $result=Backup-DomeniaDatabase
    if([string]::IsNullOrWhiteSpace([string]$result)){throw 'Aucune sauvegarde creee.'}
    Write-Host ('Sauvegarde terminee : '+$result)
    Write-Host ('SHA-256 : '+(Get-FileHash -LiteralPath $result -Algorithm SHA256).Hash)
}
