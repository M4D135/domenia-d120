# Point 139: worker body of the offline diagnostic folder of the Atelier. The dossier is produced by the local automation
# interface itself (wad\Domenia-Automate.ps1, checked against the package manifest), in this worker runspace:
# read-only SQLite, no network, no directory bind, no credential. One single-quoted here-string, pinned by SHA-256.
function Get-DomeniaOfflineDossierWorkerCode {
    return @'
$cliPath=[IO.Path]::GetFullPath([string]$Payload.ScriptPath)
if(([IO.Path]::GetFileName($cliPath) -cne 'Domenia-Automate.ps1') -or (-not [IO.File]::Exists($cliPath))){throw 'Interface automatisable absente du paquet : dossier non produit.'}
$arguments=@{Command='dossier';DatabasePath=[string]$Payload.DatabasePath;OutputPath=[string]$Payload.OutputPath;Sections=@($Payload.Sections);Limit=[int]$Payload.Limit;Build=[string]$Payload.Build;PassThru=$true}
if([string]$Payload.OrganizationalUnit){$arguments.OrganizationalUnit=[string]$Payload.OrganizationalUnit}
if(@($Payload.Guids).Count -gt 0){$arguments.Guids=@($Payload.Guids)}
$result=& $cliPath @arguments
if(($null -eq $result) -or ([string]$result.Command -cne 'dossier') -or (@($result.Items).Count -ne 1)){throw 'Dossier non confirmé par lʼinterface automatisable.'}
$item=@($result.Items)[0]
if(-not [IO.Directory]::Exists([string]$item.Dossier)){throw 'Dossier annoncé introuvable après écriture.'}
[pscustomobject]@{Path=[string]$item.Dossier;Files=@($item.Fichiers);Sections=@($item.Sections);GeneratedUtc=[string]$result.GeneratedUtc;Source=$result.Source}
'@
}
