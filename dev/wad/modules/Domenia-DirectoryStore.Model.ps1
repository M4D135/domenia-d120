# Typed, permitted directory observations. Rendering never mutates these records.
# The collector keeps the actual LDAP field mask before building any display row.
function Get-DomeniaDirectoryStoreWorkerPrelude {
    return @'
function New-WDirectoryStoreProperties {
    param($Properties,[string[]]$Names=@())
    $safe=@{}
    $available=@();if($Properties -is [Collections.IDictionary]){$available=@($Properties.Keys)}else{$available=@($Properties.PropertyNames)}
    foreach($rawName in $available){
        $name=([string]$rawName).ToLowerInvariant()
        if($Names.Count -and $Names -notcontains $name -and $name -notmatch '^__(member|memberof)(complete|note)$'){continue}
        if($name -match '^(unicodepwd|userpassword|unixuserpassword|cleartextpassword|dbcspwd|supplementalcredentials|ntpwdhistory|lmpwdhistory|currentvalue|priorvalue|peklist|trustauthincoming|trustauthoutgoing|ms-mcs-admpwd|mslaps-password|mslaps-encryptedpassword|mslaps-encryptedpasswordhistory|mslaps-encrypteddsrmpassword|mslaps-encrypteddsrmpasswordhistory|msfve-recoverypassword|msfve-keypackage|msds-managedpassword|msds-managedpasswordid|msds-managedpasswordpreviousid|msds-keycredentiallink)$'){continue}
        $values=[Collections.Generic.List[object]]::new()
        $rawValues=$Properties[$rawName]
        if($rawValues -is [byte[]]){$rawValues=,([byte[]]$rawValues)}
        foreach($raw in $rawValues){
            if($null -eq $raw){continue}
            $value=Convert-WDirectoryValue -Name $name -Value $raw
            if($value -is [datetime]){$value=$value.ToUniversalTime().ToString('o')}
            if($null -ne $value){$values.Add($value)}
        }
        $safe[$name]=$values.ToArray()
    }
    return $safe
}
'@
}

function ConvertTo-DomeniaDirectoryPropertyMap {
    param($Properties)
    $map=@{}
    if($Properties -is [Collections.IDictionary]){
        foreach($key in $Properties.Keys){$value=$Properties[$key];$map[([string]$key).ToLowerInvariant()]=$(if($value -is [byte[]]){@(,$value)}else{@($value)})}
    }elseif($null -ne $Properties){
        foreach($p in $Properties.PSObject.Properties){$value=$p.Value;$map[([string]$p.Name).ToLowerInvariant()]=$(if($value -is [byte[]]){@(,$value)}else{@($value)})}
    }
    return $map
}

function Get-DomeniaDirectoryPropertyValue {
    param([Collections.IDictionary]$Properties,[string]$Name,$Default='')
    if($null -eq $Properties -or -not $Properties.Contains($Name)){return $Default}
    $values=@($Properties[$Name]);if(-not $values.Count -or $null -eq $values[0]){return $Default}
    return $values[0]
}

function Get-DomeniaDirectoryStoredType {
    param([Collections.IDictionary]$Properties,[string]$Fallback='Objet')
    $classes=@($Properties['objectclass'])
    if($classes -contains 'computer'){return 'Machine'}
    if($classes -contains 'user'){return 'Utilisateur'}
    if($classes -contains 'group'){return 'Groupe'}
    if($classes -contains 'organizationalUnit'){return 'OU'}
    if($classes -contains 'container' -or $classes -contains 'builtinDomain'){return 'Conteneur'}
    return $Fallback
}

function ConvertTo-DomeniaDirectoryDisplayRow {
    param($Properties,[string]$Type='',[switch]$Normalized)
    # Internal callers already own a normalized map; rendering only reads it.
    $p=if($Normalized -and $Properties -is [Collections.IDictionary]){$Properties}else{ConvertTo-DomeniaDirectoryPropertyMap $Properties}
    if(-not $Type){$Type=Get-DomeniaDirectoryStoredType $p}
    $login=[string](Get-DomeniaDirectoryPropertyValue $p 'samaccountname')
    $upn=[string](Get-DomeniaDirectoryPropertyValue $p 'userprincipalname')
    if($Type -eq 'Machine'){$login=$login.TrimEnd([char]36);$upn=[string](Get-DomeniaDirectoryPropertyValue $p 'dnshostname')}
    $state='Etat non determine';$uac=0L
    if([long]::TryParse([string](Get-DomeniaDirectoryPropertyValue $p 'useraccountcontrol'),[ref]$uac)){
        $state=if(($uac -band 2) -ne 0){'Desactive'}else{'Actif'}
        $computed=0L
        if([long]::TryParse([string](Get-DomeniaDirectoryPropertyValue $p 'msds-user-account-control-computed'),[ref]$computed)){
            if(($computed -band 16) -ne 0){$state+=' / Verrouille'}
            if(($computed -band 8388608) -ne 0){$state+=' / Mot de passe expire'}
        }elseif((ConvertTo-DomeniaAdInt64 (Get-DomeniaDirectoryPropertyValue $p 'lockouttime' 0)) -gt 0){$state+=' / Verrouillage a verifier'}
    }
    $changed=ConvertTo-DomeniaAdDate (Get-DomeniaDirectoryPropertyValue $p 'whenchanged')
    $last=ConvertTo-DomeniaAdDate (Get-DomeniaDirectoryPropertyValue $p 'lastlogontimestamp')
    return [pscustomobject]@{
        Type=$Type;Name=[string](Get-DomeniaDirectoryPropertyValue $p 'name');Login=$login;UPN=$upn
        Mail=[string](Get-DomeniaDirectoryPropertyValue $p 'mail');Description=[string](Get-DomeniaDirectoryPropertyValue $p 'description')
        Changed=$(if($null -ne $changed){$changed.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}else{''})
        DN=[string](Get-DomeniaDirectoryPropertyValue $p 'distinguishedname');State=$state
        OS=[string](Get-DomeniaDirectoryPropertyValue $p 'operatingsystem')
        LastLogon=$(if($null -ne $last){$last.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}else{''})
        Guid=(ConvertTo-DomeniaGuidText (Get-DomeniaDirectoryPropertyValue $p 'objectguid'))
        AdminCount=[string](Get-DomeniaDirectoryPropertyValue $p 'admincount')
    }
}

function ConvertTo-DomeniaDirectoryStoreChange {
    param($Properties,[string]$Type='',[string]$ObservedAtUtc,[string]$Source='')
    $p=ConvertTo-DomeniaDirectoryPropertyMap $Properties
    $allowed=@(Get-DomeniaSafeObjectPropertyNames)+@('ms-mcs-admpwdexpirationtime','mslaps-passwordexpirationtime')
    foreach($attribute in @($p.Keys)){
        if(($allowed -notcontains $attribute -and $attribute -notmatch '^__(member|memberof)(complete|note)$') -or (Test-DomeniaSensitiveAttributeName $attribute)){[void]$p.Remove($attribute)}
    }
    $guid=ConvertTo-DomeniaGuidText (Get-DomeniaDirectoryPropertyValue $p 'objectguid')
    $dn=[string](Get-DomeniaDirectoryPropertyValue $p 'distinguishedname')
    if(-not $guid -or -not $dn){throw 'Observation AD sans GUID ou DN : aucune publication non enregistrée.'}
    $at=ConvertTo-DomeniaUtcDate $ObservedAtUtc
    if($null -eq $at){throw 'Observation AD sans date de lecture valide.'}
    if(-not $Type){$Type=Get-DomeniaDirectoryStoredType $p}
    if($Type -notin @('Machine','Utilisateur','Groupe','OU','Conteneur')){throw 'Type AD non pris en charge par la base locale.'}
    $data=[ordered]@{Type=$Type;Details=$p};$fields=[Collections.Generic.List[string]]::new()
    $fields.Add('Type');$fields.Add('Details')
    $mapping=@{name='Name';samaccountname='Login';displayname='Display';description='Description';usnchanged='Usn'}
    $mapping[$(if($Type -eq 'Machine'){'dnshostname'}else{'userprincipalname'})]='Upn'
    foreach($attribute in $mapping.Keys){
        if(-not $p.ContainsKey($attribute)){continue}
        $field=[string]$mapping[$attribute];$value=Get-DomeniaDirectoryPropertyValue $p $attribute
        if($field -eq 'Usn'){$value=ConvertTo-DomeniaAdInt64 $value;if($null -eq $value){continue}}
        else{$value=[string]$value}
        $data[$field]=$value;$fields.Add($field)
    }
    foreach($pair in @(@('whenchanged','WhenChanged'),@('lastlogontimestamp','LastLogon'))){
        if($p.ContainsKey($pair[0])){
            $date=ConvertTo-DomeniaAdDate (Get-DomeniaDirectoryPropertyValue $p $pair[0])
            $data[$pair[1]]=$(if($null -ne $date){$date.ToUniversalTime().ToString('o')}else{''});$fields.Add($pair[1])
        }
    }
    if($p.ContainsKey('useraccountcontrol')){
        $uac=ConvertTo-DomeniaAdInt64 (Get-DomeniaDirectoryPropertyValue $p 'useraccountcontrol')
        if($null -ne $uac){$data.State=if(($uac -band 2) -ne 0){'Desactive'}else{'Actif'};$fields.Add('State')}
    }
    # Extra is a composite summary. A partial projection must not erase its unread half.
    $parts=if($Type -eq 'Machine'){@('operatingsystem','location')}else{@('department','title')}
    if($p.ContainsKey($parts[0]) -and $p.ContainsKey($parts[1])){
        $data.Extra=(@($parts|ForEach-Object{[string](Get-DomeniaDirectoryPropertyValue $p $_)}|Where-Object{$_}) -join ' / ');$fields.Add('Extra')
    }
    $facts=[ordered]@{}
    if($Type -eq 'Machine'){
        if($p.ContainsKey('operatingsystemversion')){$facts.OsVersion=[string](Get-DomeniaDirectoryPropertyValue $p 'operatingsystemversion')}
        foreach($pair in @(@('whencreated','WhenCreated'),@('pwdlastset','PwdLastSet'))){
            if($p.ContainsKey($pair[0])){$date=ConvertTo-DomeniaAdDate (Get-DomeniaDirectoryPropertyValue $p $pair[0]);$facts[$pair[1]]=$(if($null -ne $date){$date.ToUniversalTime().ToString('o')}else{''})}
        }
        foreach($pair in @(@('mslaps-passwordexpirationtime','Windows'),@('ms-mcs-admpwdexpirationtime','Legacy'))){
            if($p.ContainsKey($pair[0])){
                $date=ConvertTo-DomeniaAdDate (Get-DomeniaDirectoryPropertyValue $p $pair[0])
                if($null -ne $date){$facts.LapsKind=$pair[1];$facts.LapsExpiry=$date.ToUniversalTime().ToString('o');break}
            }
        }
    }
    return [pscustomobject]@{Kind='DirectoryObject';Guid=$guid;DN=$dn;ObservedAtUtc=$at.ToUniversalTime().ToString('o');Source=$Source;Data=[pscustomobject]$data;Fields=$fields.ToArray();Facts=$(if($facts.Count){[pscustomobject]$facts}else{$null})}
}

function ConvertFrom-DomeniaDirectoryCommittedRow {
    param($Row)
    $p=ConvertTo-DomeniaDirectoryPropertyMap (Get-DomeniaMember $Row 'Details' @{})
    # Identity and summary columns also cover imported legacy records without Details.
    $fallback=@{objectguid='Guid';distinguishedname='DN';name='Name';samaccountname='Login';displayname='Display';description='Description';whenchanged='WhenChanged';lastlogontimestamp='LastLogon'}
    foreach($attribute in $fallback.Keys){if(-not $p.ContainsKey($attribute)){$p[$attribute]=@((Get-DomeniaMember $Row $fallback[$attribute] ''))}}
    $type=[string](Get-DomeniaMember $Row 'Type' '')
    $upnAttribute=if($type -eq 'Machine'){'dnshostname'}else{'userprincipalname'}
    if(-not $p.ContainsKey($upnAttribute)){$p[$upnAttribute]=@((Get-DomeniaMember $Row 'Upn' ''))}
    $display=ConvertTo-DomeniaDirectoryDisplayRow -Properties $p -Type $type -Normalized
    if(-not $p.ContainsKey('useraccountcontrol') -and [string](Get-DomeniaMember $Row 'State' '')){$display.State=[string]$Row.State}
    return [pscustomobject]@{Properties=$p;Row=$display;Type=$type;DN=[string](Get-DomeniaMember $Row 'DN' '');Guid=[string](Get-DomeniaMember $Row 'Guid' '')}
}
