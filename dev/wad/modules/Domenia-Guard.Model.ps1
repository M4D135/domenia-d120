# Pure, bounded models. No WPF, credentials, remote calls or file writes.
function Get-DomeniaStructuredError {
    param($ErrorValue,[string]$Phase='Unknown',[string]$Provider='Unknown',[string]$Target='')
    # Self-contained on purpose: this definition is copied alone into every worker runspace.
    $ex=$null;$text='';$native=0L;$code=0L;$allText=''
    if($ErrorValue -is [Management.Automation.ErrorRecord]){$ex=$ErrorValue.Exception}
    elseif($ErrorValue -is [Exception]){$ex=$ErrorValue}
    else{$text=[string]$ErrorValue;$allText=$text}
    for($i=0;$null -ne $ex -and $i -lt 8;$i++){
        $code=([long]$ex.HResult -band 0xffffffffL)
        if($ex.PSObject.Properties['NativeErrorCode']){$native=[long]$ex.NativeErrorCode}
        elseif($ex.GetType().FullName -eq 'System.DirectoryServices.Protocols.LdapException'){$native=[long]$ex.ErrorCode}
        $text=[string]$ex.Message
        $allText=$allText+' '+$text
        if($native -in @(5,49,50,1326,1330,1331,1909) -or $code -in @(2147942405,2147943726,2147950744,2148074252,2148074254)){break}
        $ex=$ex.InnerException
    }
    # The worker marker may be wrapped by EndInvoke ("Exception calling ...") or by an outer exception:
    # it is searched anywhere in the whole exception chain, not only at the start of the last message.
    $tagKind=''
    if($allText -match '\[DOMENIA:([A-Za-z]+);([0-9]+);(0x[0-9A-Fa-f]{8})\]'){$tagKind=$matches[1];$native=[long]$matches[2];$code=[Convert]::ToInt64($matches[3].Substring(2),16)}
    $kind='Unknown';$retry=$false
    if($native -in @(1326,49) -or $code -in @(2147943726,2148074252,2148074254)){$kind='LogonFailure'}
    elseif($native -eq 1909 -or $code -eq 2147944309){$kind='AccountLocked'}
    elseif($native -in @(1330,1331)){$kind='AccountUnavailable'}
    elseif($native -in @(5,50) -or $code -in @(2147942405,2147950744)){$kind='AccessDenied'}
    elseif($native -in @(53,64,1722,1460) -or $code -in @(2147944122,2147943860)){$kind='Unavailable';$retry=$true}
    # Compatibility fallback for old string-only workers. A timeout never implies wrong credentials.
    elseif($text -match '(?i)ETAT INCONNU|resultat.*non confirme'){$kind='Uncertain'}
    elseif($text -match '(?i)timeout|timed out|delai.*depasse|délai.*dépassé|RPC.*indisponible'){$kind='Unavailable';$retry=$true}
    elseif($text -match '(?i)ModuleMissing|module.*(?:absent|manquant|missing)'){$kind='ModuleUnavailable'}
    elseif($text -match '(?i)access.*denied|unauthorized|d[eé]chiffrement.*refus|droit de d[eé]chiffrement|d[eé]chiffreur.*autoris|acc[eè]s.*refus|insufficient.*access|0x80070005|0x80072098'){$kind='AccessDenied'}
    elseif($text -match '(?i)invalid credentials|logon failure|0x8007052e|identifiants.*rejet|user name or password is incorrect|nom d.utilisateur ou (?:le )?mot de passe (?:est )?incorrect'){$kind='LogonFailure'}
    if($kind -eq 'Unknown' -and $tagKind -in @('AccessDenied','LogonFailure','AccountLocked','AccountUnavailable','ModuleUnavailable','Unavailable','Uncertain')){$kind=$tagKind}
    [pscustomobject]@{Kind=$kind;Code=('0x{0:X8}' -f $code);NativeCode=$native;Phase=$Phase;Provider=$Provider;Target=$Target;Retryable=$retry;CanOfferCredential=($kind -in @('AccessDenied','LogonFailure'));Uncertain=($kind -eq 'Uncertain')}
}
function Get-DomeniaLinkFingerprint {
    param($Link)
    if($null -eq $Link){return ''}
    $v=[ordered]@{}
    foreach($n in @('UserLogin','Computer','Source','Confidence','VerifiedInAD','When','Details','UserGuid','ComputerGuid','UserDn','ComputerDn')){$v[$n]=[string]$Link.$n}
    return Get-DomeniaLiveHash ($v|ConvertTo-Json -Compress)
}
function ConvertTo-DomeniaLinkRecord {
    param($Link)
    $v=[ordered]@{}
    foreach($n in @('UserLogin','Computer','Source','Confidence','VerifiedInAD','When','Details','UserGuid','ComputerGuid','UserDn','ComputerDn')){$v[$n]=[string]$Link.$n}
    return [pscustomobject]$v
}
function Get-DomeniaDraftFieldMap {
    return [ordered]@{
        TxtUserGivenName='givenName';TxtUserSurname='sn';TxtUserDisplayName='displayName';TxtUserMail='mail';TxtUserPhone='telephoneNumber'
        TxtUserDescription='description';TxtUserDepartment='department';TxtUserTitle='title';TxtUserOffice='physicalDeliveryOfficeName'
        TxtUserCompany='company';TxtUserStreet='streetAddress';TxtUserCity='l';TxtUserState2='st';TxtUserPostalCode='postalCode';TxtUserCountry='co';TxtUserHomePhone='homePhone';TxtUserMobile='mobile';TxtUserFax='facsimileTelephoneNumber';TxtUserIPPhone='ipPhone';TxtUserWebPage='wWWHomePage';TxtUserEmployeeId='employeeID';TxtUserProfilePath='profilePath';TxtUserScriptPath='scriptPath';TxtUserHomeDirectory='homeDirectory';TxtUserHomeDrive='homeDrive';TxtUserWorkstations='userWorkstations';TxtGroupDescription='description';TxtCompDescription='description';TxtCompLocation='location'
    }
}
function ConvertTo-DomeniaSavedSearch {
    param($Value,[string]$BaseDn)
    if($null -eq $Value -or -not $BaseDn){return $null}
    $dn=[string]$Value.DN;$query=[string]$Value.Query;$name=[string]$Value.Name
    if($name.Length -lt 1 -or $name.Length -gt 80 -or $query.Length -gt 256 -or $dn.Length -gt 4096){return $null}
    if($dn -ine $BaseDn -and -not $dn.EndsWith(','+$BaseDn,[StringComparison]::OrdinalIgnoreCase)){return $null}
    if([string]$Value.Type -notin @('Tous','Utilisateurs','Machines','Groupes','OU et conteneurs')){return $null}
    $limit=100;[void][int]::TryParse([string]$Value.Limit,[ref]$limit);$limit=[Math]::Max(1,[Math]::Min(20000,$limit))
    $mode=if([string]$Value.SearchMode -eq 'Global'){'Global'}else{'OU'}
    return [pscustomobject]@{SearchMode=$mode;Name=$name;DN=$dn;Query=$query;Type=[string]$Value.Type;Limit=$limit;Subtree=(ConvertTo-SuiteFlag $Value.Subtree -Default $true)}
}
function Get-DomeniaPercentile {
    param([double[]]$Samples,[double]$Percent=95)
    if(-not $Samples.Count){return 0.0}
    $s=@($Samples|Sort-Object);$index=[Math]::Min($s.Count-1,[Math]::Max(0,[Math]::Ceiling($Percent/100*$s.Count)-1))
    return [Math]::Round($s[$index],2)
}
