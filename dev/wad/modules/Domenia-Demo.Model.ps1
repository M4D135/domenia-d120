# Demonstration mode rules (D002, D003, D004 data set). Pure: no WPF, no network, no disk access.
# The in-memory directory is shaped like real AD results so the production consumers can read it.

function Test-DomeniaDemoProviderEnabled {
    # Strict switch: only a JSON boolean true enables the demonstration provider. The text "false" does not.
    param($Value)
    return ($Value -is [bool] -and $Value -eq $true)
}

function Test-DomeniaDemoIdentity {
    # DEMO\name, 1 to 64 characters [A-Za-z0-9._-]. Anything else is refused before any authentication.
    param([AllowNull()][string]$Identity)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return $false }
    return ([string]$Identity).Trim() -cmatch '^DEMO\\[A-Za-z0-9._-]{1,64}$'
}

function Get-DomeniaDemoBannerText {
    return 'DÉMONSTRATION — aucune connexion AD'
}

function Get-DomeniaDemoPassThroughOperations {
    # Local operations without network that keep their production worker in demonstration mode.
    return @('LiveCache','LocalStore','DocumentStore','EngineSelfTest','EmbeddedPathBrowse','LocalIndexRead')
}

function ConvertTo-DomeniaDemoWorkerContext {
    # The DemoDirectory worker never receives a credential object. Identity fields are kept for the access rules.
    param($Context,[Parameter(Mandatory=$true)][string]$RequestedOperationId)
    return [pscustomobject]@{
        OperationId='DemoDirectory'
        RequestedOperationId=$RequestedOperationId
        DemoMode=$true
        Server=''
        BaseDn=[string](Get-DomeniaMember $Context 'BaseDn' '')
        Domain=[string](Get-DomeniaMember $Context 'Domain' '')
        Netbios=[string](Get-DomeniaMember $Context 'Netbios' '')
        BindUser=[string](Get-DomeniaMember $Context 'BindUser' '')
        PageSize=[int](Get-DomeniaMember $Context 'PageSize' 300)
        AuthMode='Demo'
        Credential=$null
        UseCredential=$false
        MachineCredential=$null
        RemoteAdminCredential=$null
        RemoteAdminUser=''
        ReadOnlyMode=$true
    }
}

function New-DomeniaDemoGuidBytes {
    param([Parameter(Mandatory=$true)][string]$Guid)
    $bytes = ([guid]$Guid).ToByteArray()
    return ,$bytes
}

function New-DomeniaDemoSidBytes {
    param([Parameter(Mandatory=$true)][int]$Rid)
    $sid = New-Object System.Security.Principal.SecurityIdentifier ('S-1-5-21-1001-2002-3003-' + $Rid)
    $bytes = New-Object byte[] $sid.BinaryLength
    $sid.GetBinaryForm($bytes,0)
    return ,$bytes
}

function New-DomeniaDemoDirectory {
    # About thirty objects faithful to AD types: GUID and SID as byte arrays, dates as DateTime, counters as
    # Int64, multi-valued objectClass, coherent member / memberOf, special characters in names and RDNs.
    param([int]$LatencyMs=0)
    $base = 'DC=demo,DC=invalid'
    $schema = 'CN=Schema,CN=Configuration,' + $base
    $created = [datetime]::SpecifyKind([datetime]'2024-03-04T08:15:00',[DateTimeKind]::Utc)
    $changed = [datetime]::SpecifyKind([datetime]'2026-09-28T14:40:00',[DateTimeKind]::Utc)
    $logon = [datetime]::SpecifyKind([datetime]'2026-09-30T07:55:00',[DateTimeKind]::Utc).ToFileTimeUtc()
    $pwdSet = [datetime]::SpecifyKind([datetime]'2026-07-01T09:00:00',[DateTimeKind]::Utc).ToFileTimeUtc()
    $never = [long]9223372036854775807
    $objects = New-Object 'System.Collections.Generic.List[object]'
    # A reference object: the builders below run in child scopes.
    $counter = [pscustomobject]@{N=0}

    $newGuid = { param([int]$n) ('d3e0' + $n.ToString('0000') + '-0000-4000-8000-' + $n.ToString('000000000000')) }
    $addOu = {
        param([string]$Dn,[string]$Name,[string[]]$DeniedFor=@())
        $counter.N++
        $objects.Add([pscustomobject]@{DN=$Dn;DeniedFor=@($DeniedFor);Attributes=[ordered]@{
            objectClass=@('top','organizationalUnit');objectCategory=@('CN=Organizational-Unit,' + $schema);name=@($Name);ou=@($Name)
            distinguishedName=@($Dn);objectGUID=@(,(New-DomeniaDemoGuidBytes (& $newGuid $counter.N)));whenCreated=@($created);whenChanged=@($changed)
            uSNChanged=@([long](12000 + $counter.N));description=@('Unite de demonstration')
        }})
    }
    $addContainer = {
        param([string]$Dn,[string]$Name,[string]$Class)
        $counter.N++
        $category = 'CN=Container,' + $schema
        if ($Class -eq 'builtinDomain') { $category = 'CN=Builtin-Domain,' + $schema }
        $objects.Add([pscustomobject]@{DN=$Dn;DeniedFor=@();Attributes=[ordered]@{
            objectClass=@('top',$Class);objectCategory=@($category);name=@($Name);cn=@($Name);distinguishedName=@($Dn)
            objectGUID=@(,(New-DomeniaDemoGuidBytes (& $newGuid $counter.N)));whenCreated=@($created);whenChanged=@($changed)
            uSNChanged=@([long](12000 + $counter.N));isCriticalSystemObject=@($true)
        }})
    }
    $addUser = {
        param([string]$Dn,[string]$Name,[string]$Sam,[string]$Given,[string]$Surname,[int]$Uac,[int]$Computed,[long]$Lockout,[string[]]$MemberOf=@(),[string[]]$DeniedFor=@(),[int]$AdminCount=0)
        $counter.N++
        $attributes = [ordered]@{
            objectClass=@('top','person','organizationalPerson','user');objectCategory=@('CN=Person,' + $schema)
            name=@($Name);cn=@($Name);displayName=@($Name);givenName=@($Given);sn=@($Surname);distinguishedName=@($Dn)
            sAMAccountName=@($Sam);userPrincipalName=@($Sam + '@demo.invalid');mail=@($Sam + '@demo.invalid')
            description=@('Compte de demonstration');objectGUID=@(,(New-DomeniaDemoGuidBytes (& $newGuid $counter.N)))
            objectSid=@(,(New-DomeniaDemoSidBytes (1100 + $counter.N)));userAccountControl=@($Uac)
            'msDS-User-Account-Control-Computed'=@($Computed);lockoutTime=@($Lockout);lastLogonTimestamp=@([long]$logon)
            pwdLastSet=@([long]$pwdSet);accountExpires=@($never);primaryGroupID=@(513);whenCreated=@($created);whenChanged=@($changed)
            uSNChanged=@([long](12000 + $counter.N));memberOf=@($MemberOf)
        }
        if ($AdminCount -gt 0) { $attributes['adminCount'] = @($AdminCount) }
        $objects.Add([pscustomobject]@{DN=$Dn;DeniedFor=@($DeniedFor);Attributes=$attributes})
    }
    $addComputer = {
        # Lot L01: operatingSystemVersion and the LAPS expiration (never a password) feed the fleet overview.
        param([string]$Dn,[string]$Name,[string]$Dns,[string]$Version = '10.0 (26100)',[string]$LapsAttribute = '',$LapsExpiry = $null)
        $counter.N++
        $attributes = [ordered]@{
            objectClass=@('top','person','organizationalPerson','user','computer');objectCategory=@('CN=Computer,' + $schema)
            name=@($Name);cn=@($Name);distinguishedName=@($Dn);sAMAccountName=@($Name + '$');description=@('Poste de demonstration')
            objectGUID=@(,(New-DomeniaDemoGuidBytes (& $newGuid $counter.N)));objectSid=@(,(New-DomeniaDemoSidBytes (1100 + $counter.N)))
            userAccountControl=@(4096);operatingSystem=@('Windows 11 Entreprise');lastLogonTimestamp=@([long]$logon);pwdLastSet=@([long]$pwdSet)
            accountExpires=@($never);primaryGroupID=@(515);whenCreated=@($created);whenChanged=@($changed);uSNChanged=@([long](12000 + $counter.N))
            memberOf=@()
        }
        if ($Dns) { $attributes['dNSHostName'] = @($Dns) }
        if ($Version) { $attributes['operatingSystemVersion'] = @($Version) }
        if ($LapsAttribute -and ($null -ne $LapsExpiry)) { $attributes[$LapsAttribute] = @([long]$LapsExpiry) }
        $objects.Add([pscustomobject]@{DN=$Dn;DeniedFor=@();Attributes=$attributes})
    }
    $addGroup = {
        param([string]$Dn,[string]$Name,[string]$Sam,[string[]]$Members=@())
        $counter.N++
        $objects.Add([pscustomobject]@{DN=$Dn;DeniedFor=@();Attributes=[ordered]@{
            objectClass=@('top','group');objectCategory=@('CN=Group,' + $schema);name=@($Name);cn=@($Name);distinguishedName=@($Dn)
            sAMAccountName=@($Sam);description=@('Groupe de demonstration');groupType=@(-2147483646)
            objectGUID=@(,(New-DomeniaDemoGuidBytes (& $newGuid $counter.N)));objectSid=@(,(New-DomeniaDemoSidBytes (1100 + $counter.N)))
            whenCreated=@($created);whenChanged=@($changed);uSNChanged=@([long](12000 + $counter.N));member=@($Members);memberOf=@()
        }})
    }
        $users = 'OU=Utilisateurs,OU=Siege,' + $base
    $postes = 'OU=Postes,OU=Siege,' + $base
    $jean = 'CN=Jean Dupont,' + $users
    $alex = 'CN=Alex Démo,' + $users
    $luc = "CN=Luc O'Brien," + $users
    $compta = 'CN=GG-Compta,OU=Siege,' + $base
    $tous = 'CN=GG-Tous,OU=Siege,' + $base
    $vide = 'CN=GG-Vide,OU=Siege,' + $base

    & $addOu ('OU=Siege,' + $base) 'Siege'
    & $addOu $users 'Utilisateurs'
    & $addOu $postes 'Postes'
    & $addOu ('OU=Agences,' + $base) 'Agences'
    & $addOu ('OU=Lyon,OU=Agences,' + $base) 'Lyon'
    & $addOu ('OU=Marseille,OU=Agences,' + $base) 'Marseille'
    & $addOu ('OU=Restreint,' + $base) 'Restreint'
    & $addContainer ('CN=Users,' + $base) 'Users' 'container'
    & $addContainer ('CN=Computers,' + $base) 'Computers' 'container'
    & $addContainer ('CN=Builtin,' + $base) 'Builtin' 'builtinDomain'

    & $addUser $jean 'Jean Dupont' 'jdupont' 'Jean' 'Dupont' 512 0 0 @($compta,$tous)
    & $addUser ('CN=Marie Martin,' + $users) 'Marie Martin' 'mmartin' 'Marie' 'Martin' 512 16 ([long]$logon) @()
    & $addUser ('CN=Paul Durand,' + $users) 'Paul Durand' 'pdurand' 'Paul' 'Durand' 514 0 0 @()
    & $addUser $alex 'Alex Démo' 'ademo' 'Alex' 'Démo' 512 0 0 @($tous)
    & $addUser $luc "Luc O'Brien" 'lobrien' 'Luc' "O'Brien" 512 0 0 @($tous)
    & $addUser ('CN=Sam (Support),' + $users) 'Sam (Support)' 'ssupport' 'Sam' 'Support' 512 0 0 @()
    & $addUser ('CN=Dupont\, Jeanne,' + $users) 'Dupont, Jeanne' 'jeanne.dupont' 'Jeanne' 'Dupont' 512 0 0 @()
    & $addUser ('CN=Demo Operateur,CN=Users,' + $base) 'Demo Operateur' 'demo.operateur' 'Demo' 'Operateur' 512 0 0 @()
    & $addUser ('CN=Demo Admin,CN=Users,' + $base) 'Demo Admin' 'demo.admin' 'Demo' 'Admin' 512 0 0 @() @() 1
    & $addUser ('CN=Compte Restreint,OU=Restreint,' + $base) 'Compte Restreint' 'restreint' 'Compte' 'Restreint' 512 0 0 @() @('DEMO\demo.operateur')

    $lapsSoon = [datetime]::SpecifyKind([datetime]'2026-11-30T08:00:00',[DateTimeKind]::Utc).ToFileTimeUtc()
    $lapsPast = [datetime]::SpecifyKind([datetime]'2026-09-01T08:00:00',[DateTimeKind]::Utc).ToFileTimeUtc()
    & $addComputer ('CN=PC-DEMO-01,' + $postes) 'PC-DEMO-01' 'pc-demo-01.demo.invalid' '10.0 (26100)' 'msLAPS-PasswordExpirationTime' $lapsSoon
    & $addComputer ('CN=PC-DEMO-02,OU=Lyon,OU=Agences,' + $base) 'PC-DEMO-02' '' '10.0 (22631)'
    & $addComputer ('CN=PC-DEMO-03,CN=Computers,' + $base) 'PC-DEMO-03' 'pc-demo-03.demo.invalid' '10.0 (26100)' 'ms-Mcs-AdmPwdExpirationTime' $lapsPast

    & $addGroup $vide 'GG-Vide' 'GG-Vide' @()
    & $addGroup $compta 'GG-Compta' 'GG-Compta' @($jean)
    & $addGroup $tous 'GG-Tous' 'GG-Tous' @($jean,$alex,$luc)

    return [pscustomobject]@{
        Format='DomeniaDemoDirectory/1'
        BaseDn=$base
        Domain='demo.invalid'
        Netbios='DEMO'
        LatencyMs=[Math]::Max(0,[Math]::Min(5000,$LatencyMs))
        Objects=$objects.ToArray()
    }
}
