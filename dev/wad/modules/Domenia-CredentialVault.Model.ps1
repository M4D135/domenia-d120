# Optional local Windows vault. This module never authenticates, starts a collector or resets a refusal guard.
# Each native call requires explicit -Enabled; saving additionally requires manual authentication confirmation.
$script:DomeniaCredentialVaultNativePath = Join-Path $PSScriptRoot 'Domenia-CredentialVault.Native.cs'

function Get-DomeniaCredentialVaultTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DomainDn,[Parameter(Mandatory=$true)][string]$Scope,[Parameter(Mandatory=$true)][string]$UserName)
    $domain=$DomainDn.Trim();$scopeName=$Scope.Trim();$account=$UserName.Trim()
    if(-not $domain -or $domain.Length -gt 2048 -or $domain -match '[\x00-\x1f\x7f]'){throw 'Domaine du coffre absent ou invalide.'}
    if(-not $account -or $account.Length -gt 256 -or $account -match '[\x00-\x1f\x7f]'){throw 'Identifiant du coffre absent ou hors limite.'}
    # Same persisted scopes as Get-DomeniaAccountPreferenceScope. Never infer an authority alias.
    if($scopeName -notin @('Directory','Remote','Laps','BitLocker') -and $scopeName -notmatch '^AD:[A-Za-z][A-Za-z0-9_.-]{0,63}$' -and $scopeName -cnotmatch '^RemoteLocal:[a-z0-9][a-z0-9._-]{0,252}$'){throw 'Usage du coffre inconnu.'}
    if($scopeName -cmatch '^RemoteLocal:(.+)$'){
        $machine=$Matches[1]
        if($account -notmatch '^(?<Authority>[^\\]+)\\(?<Login>[^\\]+)$' -or ($Matches.Authority -ne '.' -and $Matches.Authority -ine $machine)){throw 'Ce coffre local exige le compte du poste exact.'}
    }elseif($account.StartsWith('.\',[StringComparison]::Ordinal)){throw 'Un compte local exige un perimetre RemoteLocal precis.'}
    # Length-prefix each component: newline/delimiter collisions are impossible. Server and DB path are excluded.
    $parts=@('DomeniaCredentialVault/v1',$domain.ToLowerInvariant(),$scopeName.ToLowerInvariant(),$account.ToLowerInvariant())
    $builder=[Text.StringBuilder]::new()
    foreach($part in $parts){[void]$builder.Append($part.Length.ToString([Globalization.CultureInfo]::InvariantCulture));[void]$builder.Append(':');[void]$builder.Append($part)}
    $bytes=[Text.Encoding]::UTF8.GetBytes($builder.ToString());$sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=$sha.ComputeHash($bytes);return 'Domenia:v1:'+([BitConverter]::ToString($hash).Replace('-','').ToLowerInvariant())}finally{$sha.Dispose()}
}

function Initialize-DomeniaCredentialVault {
    [CmdletBinding()]
    param()
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Le coffre des identifiants est disponible uniquement sous Windows.'}
    if($null -eq ('Domenia.Security.CredentialVault' -as [type])){
        if(-not [IO.File]::Exists($script:DomeniaCredentialVaultNativePath)){throw 'Module natif du coffre absent.'}
        Add-Type -Path $script:DomeniaCredentialVaultNativePath -ErrorAction Stop | Out-Null
    }
}

function Get-DomeniaCredentialVaultCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DomainDn,[Parameter(Mandatory=$true)][string]$Scope,[Parameter(Mandatory=$true)][string]$UserName,[switch]$Enabled)
    if(-not $Enabled){return $null}
    $target=Get-DomeniaCredentialVaultTarget -DomainDn $DomainDn -Scope $Scope -UserName $UserName
    Initialize-DomeniaCredentialVault
    $password=[Domenia.Security.CredentialVault]::Read($target,$UserName.Trim())
    if($null -eq $password){return $null}
    try{$credential=[Management.Automation.PSCredential]::new($UserName.Trim(),$password);$password=$null;return $credential}finally{if($null -ne $password){$password.Dispose()}}
}

function Save-DomeniaCredentialVaultCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DomainDn,[Parameter(Mandatory=$true)][string]$Scope,[Parameter(Mandatory=$true)][Management.Automation.PSCredential]$Credential,[switch]$Enabled,[switch]$AuthenticationConfirmed)
    if(-not $Enabled){return [pscustomobject]@{Saved=$false;Disabled=$true}}
    if(-not $AuthenticationConfirmed){throw 'Enregistrement refuse : confirmer d abord une authentification manuelle pour cet usage.'}
    $target=Get-DomeniaCredentialVaultTarget -DomainDn $DomainDn -Scope $Scope -UserName $Credential.UserName
    if($null -eq $Credential.Password -or $Credential.Password.Length -eq 0 -or $Credential.Password.Length -gt 1280){throw 'Secret absent ou hors limite du coffre Windows (2560 octets).'}
    Initialize-DomeniaCredentialVault
    [Domenia.Security.CredentialVault]::Write($target,$Credential.UserName.Trim(),$Credential.Password)
    return [pscustomobject]@{Saved=$true;Disabled=$false}
}

function Remove-DomeniaCredentialVaultCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DomainDn,[Parameter(Mandatory=$true)][string]$Scope,[Parameter(Mandatory=$true)][string]$UserName,[switch]$Enabled)
    if(-not $Enabled){return [pscustomobject]@{Removed=$false;Disabled=$true}}
    $target=Get-DomeniaCredentialVaultTarget -DomainDn $DomainDn -Scope $Scope -UserName $UserName
    Initialize-DomeniaCredentialVault
    $removed=[Domenia.Security.CredentialVault]::Delete($target)
    return [pscustomobject]@{Removed=$removed;Disabled=$false}
}

function ConvertTo-DomeniaVaultLoginKey {
    # Decision David 2026-10-19: comparison key of the remembered login account, without its domain part
    # (CNAMTS\compte, compte@cnamts.local and compte are the same account), lower case. The vault entry itself stays
    # bound to the exact remembered account (Get-DomeniaCredentialVaultTarget).
    param([AllowEmptyString()][string]$Login)
    $key=([string]$Login).Trim()
    if($key.Contains('\')){$key=$key.Substring($key.LastIndexOf('\')+1)}
    if($key.Contains('@')){$key=$key.Substring(0,$key.IndexOf('@'))}
    return $key.Trim().ToLowerInvariant()
}

function Get-DomeniaVaultLoginReason {
    # Why « Utiliser le coffre » of the login window is unavailable, from the remembered account only (no vault read).
    param([AllowEmptyString()][string]$Typed='',[AllowEmptyString()][string]$Account='',[AllowEmptyString()][string]$DomainDn='',[bool]$Demo=$false)
    if($Demo){return 'Coffre indisponible en démonstration.'}
    $remembered=([string]$Account).Trim()
    if((-not ([string]$DomainDn).Trim()) -or (-not $remembered)){return 'Aucun compte mémorisé dans le coffre de ce PC : cochez « Mémoriser sur ce PC » lors dʼune connexion réussie.'}
    if((ConvertTo-DomeniaVaultLoginKey $Typed) -cne (ConvertTo-DomeniaVaultLoginKey $remembered)){return ('Coffre mémorisé pour '+$remembered+' : saisissez ce compte pour lʼutiliser.')}
    return 'Compte mémorisé pour un autre domaine que celui de la configuration.'
}
