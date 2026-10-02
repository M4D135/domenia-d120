Set-StrictMode -Version 2.0
# Pure rules. This development module is deliberately NOT loaded by the application.
function ConvertTo-DomeniaLdapLiteral {
 [CmdletBinding()] param([AllowEmptyString()][string]$Value)
 $b=New-Object Text.StringBuilder
 foreach($c in $Value.ToCharArray()) {
  switch([int]$c) { 0 {[void]$b.Append('\00')} 40 {[void]$b.Append('\28')} 41 {[void]$b.Append('\29')} 42 {[void]$b.Append('\2a')} 92 {[void]$b.Append('\5c')} default {[void]$b.Append($c)} }
 }
 return $b.ToString()
}
function Get-DomeniaRelationDirection {
 [CmdletBinding()] param([Parameter(Mandatory=$true)][ValidateSet('Utilisateur','Machine','User','Computer')][string]$SubjectType)
 if($SubjectType -in @('Utilisateur','User')){return [pscustomobject]@{SourceType='Utilisateur';TargetType='Machine';Action='Associer ce poste'}}
 return [pscustomobject]@{SourceType='Machine';TargetType='Utilisateur';Action='Associer cet utilisateur'}
}
function Test-DomeniaSameSubject {
 [CmdletBinding()] param([AllowNull()]$Expected,[AllowNull()]$Actual)
 if($null -eq $Expected -or $null -eq $Actual){return $false}
 foreach($k in @('Domain','Guid','Type','Reader','Session','Generation')){
  if($null -eq $Expected.PSObject.Properties[$k] -or $null -eq $Actual.PSObject.Properties[$k]){return $false}
  if([string]::IsNullOrWhiteSpace([string]$Expected.$k)){return $false}
  if(-not [string]::Equals([string]$Expected.$k,[string]$Actual.$k,[StringComparison]::OrdinalIgnoreCase)){return $false}
 }
 $g=[guid]::Empty
 if(-not [guid]::TryParse([string]$Expected.Guid,[ref]$g) -or $g -eq [guid]::Empty){return $false}
 return $true
}
function Test-DomeniaRelationConfirmation {
 [CmdletBinding()] param($SourceExpected,$SourceActual,$TargetExpected,$TargetActual)
 if(-not (Test-DomeniaSameSubject $SourceExpected $SourceActual)){return $false}
 if(-not (Test-DomeniaSameSubject $TargetExpected $TargetActual)){return $false}
 $direction=Get-DomeniaRelationDirection ([string]$SourceExpected.Type)
 $targetType=[string]$TargetActual.Type
 if($targetType -eq 'User'){$targetType='Utilisateur'}
 if($targetType -eq 'Computer'){$targetType='Machine'}
 if($targetType -ne $direction.TargetType){return $false}
 if([string]$SourceActual.Domain -ine [string]$TargetActual.Domain){return $false}
 if([string]$SourceActual.Session -cne [string]$TargetActual.Session){return $false}
 return $true
}
function Get-DomeniaCacheReadPolicy {
 [CmdletBinding()] param([bool]$HasSnapshot,[bool]$IdentityMatches,[bool]$FreshReadConfirmed,[bool]$Offline,[bool]$WriteUncertain)
 $view=$HasSnapshot -and $IdentityMatches
 [pscustomobject]@{CanView=$view;CanCopy=$view;CanEdit=($view -and $FreshReadConfirmed -and -not $Offline -and -not $WriteUncertain);Historical=($view -and -not $FreshReadConfirmed);CanRetry=(-not $WriteUncertain);Reason=$(if(-not $IdentityMatches){'Identite non confirmee'}elseif($WriteUncertain){'Operation a verifier'}elseif($Offline){'Consultation historique hors ligne'}elseif(-not $FreshReadConfirmed){'Donnees en cache, relecture necessaire'}else{'Lecture AD confirmee'})}
}
function Get-DomeniaDetectionScopePlan {
 [CmdletBinding()] param([Parameter(Mandatory=$true)][ValidateSet('Candidates','Loaded','OU')][string]$RequestedScope,[AllowEmptyString()][string]$OuDn,[AllowEmptyString()][string]$DomainDn,[object[]]$Candidates=@(),[ValidateRange(1,50)][int]$Limit=20)
 if($RequestedScope -eq 'OU' -and ([string]::IsNullOrWhiteSpace($OuDn) -or $OuDn -ieq $DomainDn)){
  return [pscustomobject]@{Allowed=$false;Scope=$RequestedScope;OuDn=$OuDn;Limit=$Limit;Candidates=@();Reason='Choisissez une OU explicite; le domaine entier ne sera pas substitue.'}
 }
 $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 $list=New-Object 'System.Collections.Generic.List[object]'
 foreach($candidate in @($Candidates)){
  if($null -eq $candidate){continue}
  if($null -eq $candidate.PSObject.Properties['Guid'] -or $null -eq $candidate.PSObject.Properties['Domain']){continue}
  $guid=[guid]::Empty
  if(-not [guid]::TryParse([string]$candidate.Guid,[ref]$guid) -or $guid -eq [guid]::Empty){continue}
  $key=([string]$candidate.Domain)+'|'+$guid.ToString('D')
  if($seen.Add($key) -and $list.Count -lt $Limit){$list.Add($candidate)}
 }
 $items=$list.ToArray()
 [pscustomobject]@{Allowed=($RequestedScope -eq 'OU' -or $items.Count -gt 0);Scope=$RequestedScope;OuDn=$OuDn;Limit=$Limit;Candidates=$items;Reason=$(if($items.Count){'Perimetre a confirmer avant sondes.'}elseif($RequestedScope -eq 'OU'){'Lire les candidats de cette OU avant de confirmer les sondes.'}else{'Aucun candidat disponible; choisir un autre perimetre explicitement.'})}
}
function Get-DomeniaEvidenceKind {
 [CmdletBinding()] param([string]$Source)
 if($Source -match '(?i)manual|manuel|declare'){return 'Declare'}
 if($Source -match '(?i)console|CIM|DCOM|WTS|session'){return 'Observe'}
 if($Source -match '(?i)import'){return 'Importe'}
 if($Source -match '(?i)description|kerberos|managedBy|indice'){return 'Indice'}
 return 'Source a verifier'
}
function Get-DomeniaCounterText {
 [CmdletBinding()] param([ValidateRange(0,2147483647)][int]$Count)
 if($Count -eq 0){return ''};if($Count -gt 99){return '99+'};return $Count.ToString([Globalization.CultureInfo]::InvariantCulture)
}
function Get-DomeniaResultColumns {
 [CmdletBinding()] param([Parameter(Mandatory=$true)][ValidateSet('Utilisateur','Machine','Mixte')][string]$Profile)
 switch($Profile){
  'Utilisateur' {return @('Type','Name','Login','Upn','Display','State','Association','Freshness')}
  'Machine' {return @('Type','Name','Upn','ConsoleUser','Presence','ConsoleStatus','Association','Freshness')}
  'Mixte' {return @('Type','Name','Login','Upn','State','Association','Freshness')}
 }
}
Export-ModuleMember -Function ConvertTo-DomeniaLdapLiteral,Get-DomeniaRelationDirection,Test-DomeniaSameSubject,Test-DomeniaRelationConfirmation,Get-DomeniaCacheReadPolicy,Get-DomeniaDetectionScopePlan,Get-DomeniaEvidenceKind,Get-DomeniaCounterText,Get-DomeniaResultColumns
