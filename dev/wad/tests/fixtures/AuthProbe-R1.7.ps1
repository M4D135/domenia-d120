# TEST FIXTURE ONLY. Original R1.7 authentication function. No invocation.
function Invoke-DomeniaInProcessAuthProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Request,
        [Parameter(Mandatory=$true)]$Progress
    )

    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue"
    $VerbosePreference = "SilentlyContinue"
    $DebugPreference = "SilentlyContinue"
    $InformationPreference = "SilentlyContinue"

    function Set-AuthProgress {
        param([string]$Stage,[string]$Detail="")
        try {
            $Progress["Stage"] = $Stage
            $Progress["Detail"] = $Detail
            $Progress["UpdatedAt"] = [datetime]::UtcNow
            $Progress["Sequence"] = ([int]$Progress["Sequence"]) + 1
        }
        catch { }
    }

    function Add-UniqueServer {
        param([System.Collections.ArrayList]$List,[string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return }
        $candidate = $Value.Trim().TrimStart([char]92).TrimEnd(".")
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not ($List -contains $candidate)) {
            [void]$List.Add($candidate)
        }
    }

    function Get-LdapAttributeFirst {
        param($Entry,[string]$Name)
        try {
            if ($null -ne $Entry -and $Entry.Attributes.Contains($Name) -and $Entry.Attributes[$Name].Count -gt 0) {
                return [string]$Entry.Attributes[$Name][0]
            }
        }
        catch { }
        return ""
    }

    function Get-DeepestException {
        param($ErrorRecord)
        $exception = $null
        try { $exception = $ErrorRecord.Exception } catch { }
        if ($null -eq $exception -and $ErrorRecord -is [System.Exception]) { $exception = $ErrorRecord }
        $last = $exception
        $guard = 0
        while ($null -ne $exception -and $null -ne $exception.InnerException -and $guard -lt 12) {
            $exception = $exception.InnerException
            $last = $exception
            $guard++
        }
        return $last
    }

    function Format-LdapError {
        param($ErrorRecord,[string]$ServerName)
        $outer = $null
        try { $outer = $ErrorRecord.Exception } catch { }
        $deepest = Get-DeepestException -ErrorRecord $ErrorRecord
        $ldapException = $null
        $cursor = $outer
        $guard = 0
        while ($null -ne $cursor -and $guard -lt 12) {
            if ($cursor -is [System.DirectoryServices.Protocols.LdapException]) { $ldapException = $cursor; break }
            $cursor = $cursor.InnerException
            $guard++
        }
        $code = -1
        $messages = New-Object System.Collections.ArrayList
        foreach ($candidate in @($outer,$deepest,$ldapException)) {
            try {
                $message = ([string]$candidate.Message).Trim()
                if (-not [string]::IsNullOrWhiteSpace($message) -and -not $messages.Contains($message)) { [void]$messages.Add($message) }
            }
            catch { }
        }
        if ($null -ne $ldapException) {
            try { $code = [int]$ldapException.ErrorCode } catch { }
            try {
                $serverMessage = ([string]$ldapException.ServerErrorMessage).Trim()
                if (-not [string]::IsNullOrWhiteSpace($serverMessage) -and -not $messages.Contains($serverMessage)) { [void]$messages.Add($serverMessage) }
            }
            catch { }
        }
        $messageText = (($messages.ToArray() | ForEach-Object { [string]$_ }) -join " | ")
        if ($code -eq 49) {
            # Le controleur renvoie un sous-code hexadecimal dans le message,
            # sous la forme  data 775 . Il distingue huit situations que
            # rien d autre ne permet de separer.
            $sub = ""
            $subMatch = [regex]::Match($messageText,"(?i)data\s+([0-9a-f]{3,4})")
            if ($subMatch.Success) { $sub = $subMatch.Groups[1].Value.ToLowerInvariant() }
            switch ($sub) {
                "525" { return "Ce compte n existe pas dans l annuaire." }
                "52e" { return "Mot de passe incorrect. Attention : quelques essais de plus peuvent verrouiller le compte." }
                "530" { return "Ce compte n est pas autorise a ouvrir une session a cette heure-ci." }
                "531" { return "Ce compte n est pas autorise a ouvrir une session depuis ce poste." }
                "532" { return "Le mot de passe de ce compte a expire. Change-le, puis reconnecte-toi." }
                "533" { return "Ce compte est desactive." }
                "701" { return "Ce compte a expire." }
                "773" { return "Ce compte doit changer de mot de passe avant de pouvoir se connecter." }
                "775" { return "Ce compte est VERROUILLE. Le mot de passe n est pas en cause : attends la fin du delai de verrouillage ou fais-le deverrouiller." }
                default { return "Identifiant ou mot de passe refuse par $ServerName." }
            }
        }
        if ($messageText -match "(?i)0x8007052e|8007052e|invalid credentials|logon failure|unknown user|bad password|identifiants? (?:non valides?|incorrects?)|nom d.?utilisateur.*mot de passe.*incorrect|user name or password.*incorrect|username or password.*incorrect|mot de passe.*incorrect") { return "Identifiant ou mot de passe incorrect." }
        if ($code -eq 81 -or $messageText -match "(?i)server.*not operational|cannot contact|unavailable|connexion.*impossible|nom de serveur.*introuvable|no such host") { return "Controleur $ServerName injoignable." }
        if ($code -eq 85 -or $messageText -match "(?i)time.?out|delai|delai|operation.*expir") { return "Timeout LDAP sur $ServerName." }
        if ([string]::IsNullOrWhiteSpace($messageText) -or $messageText -eq "0") { return "Echec LDAP sans detail sur $ServerName (code $code)." }
        return "$messageText (LDAP=$code, serveur=$ServerName)"
    }

    function New-AuthResult {
        param(
            [bool]$Success,
            [string]$BindUser="",
            [string]$AuthMode="",
            [string]$AuthMethod="",
            [string]$BaseDn="",
            [string]$Server="",
            [string]$Domain="",
            [string]$Netbios="",
            [string]$RootPath="",
            [string]$Error="",
            [string]$ErrorCategory="",
            [int]$Attempts=0,
            [long]$DurationMs=0
        )
        [pscustomobject]@{
            Success=$Success; BindUser=$BindUser; AuthMode=$AuthMode; AuthMethod=$AuthMethod
            BaseDn=$BaseDn; Server=$Server; Domain=$Domain; Netbios=$Netbios; RootPath=$RootPath
            Error=$Error; ErrorCategory=$ErrorCategory; Attempts=$Attempts; DurationMs=$DurationMs
            InProcess=$true; WorkerThreadId=[System.Threading.Thread]::CurrentThread.ManagedThreadId
            Apartment=[System.Threading.Thread]::CurrentThread.GetApartmentState().ToString()
        }
    }

    # Enterprise multi-infrastructure path. The legacy block below is kept only
    # as inert source compatibility; every real request returns from this path.
    function Escape-AuthLdapValue {
        param([string]$Value)
        $builder = New-Object System.Text.StringBuilder
        foreach ($character in ([string]$Value).ToCharArray()) {
            switch ($character) {
                ([char]92) { [void]$builder.Append("\5c") }
                "(" { [void]$builder.Append("\28") }
                ")" { [void]$builder.Append("\29") }
                "`0" { [void]$builder.Append("\00") }
                "*" { [void]$builder.Append("\2a") }
                default { [void]$builder.Append($character) }
            }
        }
        return $builder.ToString()
    }

    function Convert-AuthNamingContextToDns {
        param([string]$NamingContext)
        $labels = New-Object System.Collections.ArrayList
        foreach ($match in [regex]::Matches([string]$NamingContext,"(?i)(?:^|,)DC=([^,]+)")) {
            $label = ([string]$match.Groups[1].Value).Trim()
            if (-not [string]::IsNullOrWhiteSpace($label)) { [void]$labels.Add($label) }
        }
        return (@($labels) -join ".")
    }

    function Get-AuthNetbiosName {
        param($Connection,[string]$ConfigurationNamingContext,[string]$DefaultNamingContext)
        if ([string]::IsNullOrWhiteSpace($ConfigurationNamingContext) -or [string]::IsNullOrWhiteSpace($DefaultNamingContext)) { return "" }
        try {
            $escapedNc = Escape-AuthLdapValue -Value $DefaultNamingContext
            $request = [System.DirectoryServices.Protocols.SearchRequest]::new(
                $ConfigurationNamingContext,
                "(&(objectClass=crossRef)(nCName=$escapedNc))",
                [System.DirectoryServices.Protocols.SearchScope]::Subtree,
                [string[]]@("nETBIOSName")
            )
            $response = [System.DirectoryServices.Protocols.SearchResponse]$Connection.SendRequest($request)
            if ($response.Entries.Count -gt 0) { return Get-LdapAttributeFirst -Entry $response.Entries[0] -Name "nETBIOSName" }
        }
        catch { }
        return ""
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($null -ne $Request.PSObject.Properties["SelfTestOnly"] -and [bool]$Request.SelfTestOnly) {
            Set-AuthProgress -Stage "Auto-test" -Detail "Runspace d authentification interne operationnel."
            $watch.Stop()
            return New-AuthResult -Success $true -AuthMode "SelfTest" -AuthMethod "InProcess.Runspace" -DurationMs $watch.ElapsedMilliseconds
        }

        Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop | Out-Null
        $useCurrentCredentials = [bool]$Request.UseCurrentCredentials
        $rawLogin = ([string]$Request.Login).Trim()
        if (-not $useCurrentCredentials -and $null -eq $Request.Credential) {
            $watch.Stop()
            return New-AuthResult -Success $false -AuthMode "Explicit" -AuthMethod "LDAP.Protocols.Negotiate" -Error "Identifiant ou mot de passe manquant." -ErrorCategory "Input" -DurationMs $watch.ElapsedMilliseconds
        }
        if (-not $useCurrentCredentials -and [string]::IsNullOrWhiteSpace($rawLogin)) {
            try { $rawLogin = [string]$Request.Credential.UserName } catch { }
        }

        if (-not $useCurrentCredentials) {
            try {
                Set-AuthProgress -Stage "Authentification Active Directory" -Detail "Decouverte du contexte AD puis validation unique du compte saisi"
            }
            catch { }
        }

        $configuredBase = ([string]$Request.ConfiguredBase).Trim()
        $configuredServer = ([string]$Request.ConfiguredServer).Trim().TrimStart([char]92).TrimEnd(".")
        $domainHint = ([string]$Request.Domain).Trim()
        $netbiosHint = ([string]$Request.Netbios).Trim()
        if ($rawLogin.Contains("@")) {
            $upnSuffix = $rawLogin.Split("@",2)[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($upnSuffix)) { $domainHint = $upnSuffix }
        }

        $servers = New-Object System.Collections.ArrayList
        Add-UniqueServer -List $servers -Value $configuredServer
        Add-UniqueServer -List $servers -Value $domainHint
        if ($rawLogin.Contains([string][char]92)) { Add-UniqueServer -List $servers -Value ($rawLogin.Split([char]92,2)[0]) }
        try { Add-UniqueServer -List $servers -Value ([string]$env:USERDNSDOMAIN) } catch { }
        try {
            $computerDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
            try { Add-UniqueServer -List $servers -Value ([string]$computerDomain.Name) }
            finally { if ($null -ne $computerDomain) { $computerDomain.Dispose() } }
        }
        catch { }
        try { Add-UniqueServer -List $servers -Value ([string]$env:LOGONSERVER) } catch { }

        $maxServers = [Math]::Max(1,[Math]::Min(8,[int]$Request.MaxServers))
        while ($servers.Count -gt $maxServers) { $servers.RemoveAt($servers.Count - 1) }
        if ($servers.Count -eq 0) {
            $watch.Stop()
            return New-AuthResult -Success $false -AuthMode $(if($useCurrentCredentials){"Windows"}else{"Explicit"}) -AuthMethod "LDAP.Protocols.Negotiate" -Error "Aucun domaine ou controleur AD ne peut etre decouvert. Verifie le DNS ou renseigne -Server." -ErrorCategory "Configuration" -DurationMs $watch.ElapsedMilliseconds
        }

        $overallTimeout = [Math]::Max(8,[int]$Request.OverallTimeoutSeconds)
        $perServerTimeout = [Math]::Max(2,[Math]::Min(10,[int]$Request.PerServerTimeoutSeconds))
        $attempt = 0
        $lastError = "Aucune tentative effectuee."
        foreach ($serverName in @($servers)) {
            if ($watch.Elapsed.TotalSeconds -ge $overallTimeout) { break }
            $attempt++
            $connection = $null
            try {
                Set-AuthProgress -Stage "Decouverte Active Directory" -Detail "Bind LDAP et lecture RootDSE sur $serverName"
                # Pour un login explicite, utiliser ADSI/DirectoryEntry avec
                # l'identite EXACTEMENT telle qu'elle a ete saisie.
                #
                # LdapConnection + NetworkCredential interprete parfois un
                # sAMAccountName nu differemment selon le type de compte ou le
                # contexte Windows. C'est notamment visible avec certains
                # comptes administratifs qui fonctionnent dans les autres
                # outils ADSI mais sont refuses ici.
                #
                # Important securite : on ne tente aucune variante automatique
                # DOMAIN\user / user@domain. Une seule identite, une seule
                # tentative d'authentification par controleur.
                if (-not $useCurrentCredentials) {
                    # Separer strictement deux operations :
                    #   1) decouverte RootDSE avec l'identite Windows courante ;
                    #   2) UNE SEULE validation du compte explicite sur la base AD decouverte.
                    #
                    # Le mot de passe saisi ne doit jamais servir a decouvrir le domaine ou
                    # plusieurs controleurs. Cela evite de transformer une erreur de decouverte
                    # RootDSE en plusieurs tentatives d'authentification et donc en risque de lockout.
                    $discoveryRoot = $null
                    $baseAdsi = $null
                    $plainPassword = ""
                    $explicitBindAttempted = $false
                    try {
                        # RootDSE est une operation de decouverte. Sur un poste joint au domaine,
                        # la session Windows courante suffit pour lire ces metadonnees, meme si le
                        # compte administratif saisi est different.
                        $rootPath = "LDAP://$serverName/RootDSE"
                        $discoveryRoot = New-Object System.DirectoryServices.DirectoryEntry -ArgumentList @($rootPath)
                        $null = $discoveryRoot.NativeObject

                        $detectedBase = ""
                        $configurationNc = ""
                        $detectedDc = ""
                        try { $detectedBase = [string]$discoveryRoot.Properties["defaultNamingContext"][0] } catch { }
                        try { $configurationNc = [string]$discoveryRoot.Properties["configurationNamingContext"][0] } catch { }
                        try { $detectedDc = [string]$discoveryRoot.Properties["dnsHostName"][0] } catch { }

                        # Si un serveur logique (ex. CNAMTS.LOCAL) ne renvoie pas RootDSE, on peut
                        # essayer le candidat suivant SANS utiliser le mot de passe explicite.
                        if ([string]::IsNullOrWhiteSpace($detectedBase)) {
                            throw "Decouverte RootDSE incomplete sur $serverName : defaultNamingContext absent."
                        }

                        $effectiveBase = if ([string]::IsNullOrWhiteSpace($configuredBase)) { $detectedBase } else { $configuredBase }
                        $detectedDomain = Convert-AuthNamingContextToDns -NamingContext $detectedBase
                        if ([string]::IsNullOrWhiteSpace($detectedDomain)) { $detectedDomain = $domainHint }

                        # Resoudre UNE identite canonique avant le bind. Un sAMAccountName court
                        # est qualifie une seule fois avec le NETBIOS connu du domaine. On ne tente
                        # aucune succession raw / DOMAIN\\user / user@domain.
                        $detectedNetbios = $netbiosHint
                        try {
                            if ([string]::IsNullOrWhiteSpace($detectedNetbios) -and
                                -not [string]::IsNullOrWhiteSpace([string]$env:USERDOMAIN) -and
                                [string]$env:USERDOMAIN -ine [string]$env:COMPUTERNAME) {
                                $detectedNetbios = ([string]$env:USERDOMAIN).Trim()
                            }
                        }
                        catch { }
                        if ([string]::IsNullOrWhiteSpace($detectedNetbios) -and -not [string]::IsNullOrWhiteSpace($detectedDomain)) {
                            try { $detectedNetbios = (($detectedDomain -split '\.')[0]).ToUpperInvariant() } catch { }
                        }

                        $bindLogin = $rawLogin
                        if (-not $bindLogin.Contains([string][char]92) -and -not $bindLogin.Contains("@") -and -not [string]::IsNullOrWhiteSpace($detectedNetbios)) {
                            $bindLogin = "$detectedNetbios\$rawLogin"
                        }

                        $plainPassword = [string]$Request.Credential.GetNetworkCredential().Password
                        $selectedServer = if ([string]::IsNullOrWhiteSpace($detectedDc)) { [string]$serverName } else { $detectedDc }
                        $basePath = "LDAP://$selectedServer/$effectiveBase"
                        Set-AuthProgress -Stage "Authentification Active Directory" -Detail "Validation unique du compte sur $selectedServer"

                        $explicitBindAttempted = $true
                        $baseAdsi = New-Object System.DirectoryServices.DirectoryEntry -ArgumentList @(
                            $basePath,
                            $bindLogin,
                            $plainPassword,
                            [System.DirectoryServices.AuthenticationTypes]::Secure
                        )
                        # NativeObject force reellement le bind. RefreshCache force ensuite une
                        # lecture minimale sur la base pour eviter un faux positif paresseux ADSI.
                        $null = $baseAdsi.NativeObject
                        try { $baseAdsi.RefreshCache([string[]]@("distinguishedName")) } catch { $null = $baseAdsi.Properties["distinguishedName"].Value }

                        Set-AuthProgress -Stage "Termine" -Detail "Contexte AD valide sur $selectedServer"
                        $watch.Stop()
                        # BindUser est renvoye au thread UI puis devient aussi le UserName du
                        # PSCredential de session. Tous les workers utiliseront donc le meme couple
                        # identite/mot de passe que celui qui vient de reussir ce bind.
                        return New-AuthResult -Success $true -BindUser $bindLogin -AuthMode "Explicit" -AuthMethod "ADSI.DirectoryEntry+ContextDiscovery" -BaseDn $effectiveBase -Server $selectedServer -Domain $detectedDomain -Netbios $detectedNetbios -RootPath "LDAP://$selectedServer/$effectiveBase" -Attempts 1 -DurationMs $watch.ElapsedMilliseconds
                    }
                    catch {
                        $detail = Format-LdapError -ErrorRecord $_ -ServerName ([string]$serverName)

                        if ($explicitBindAttempted) {
                            # Une fois le mot de passe envoye UNE fois, ne jamais essayer un autre DC.
                            # Qu'il s'agisse d'un refus d'identite ou d'une panne reseau apres bind,
                            # l'utilisateur pourra relancer volontairement. DOMENIA ne multiplie pas les essais.
                            $watch.Stop()
                            $category = if ($detail -match "(?i)identifiant|mot de passe|compte.*verrouill|compte.*desactiv|compte.*desactiv|compte.*expir|changer de mot de passe|ouvrir une session") { "Credentials" } else { "DomainUnavailable" }
                            Set-AuthProgress -Stage "Termine" -Detail $detail
                            return New-AuthResult -Success $false -AuthMode "Explicit" -AuthMethod "ADSI.DirectoryEntry+ContextDiscovery" -Error $detail -ErrorCategory $category -Server ([string]$serverName) -Attempts 1 -DurationMs $watch.ElapsedMilliseconds
                        }

                        # Ici aucun mot de passe explicite n'a encore ete utilise. On peut donc
                        # continuer la decouverte sur le prochain candidat sans risque de lockout.
                        $lastError = $detail
                        continue
                    }
                    finally {
                        $plainPassword = ""
                        try { if ($null -ne $baseAdsi) { $baseAdsi.Dispose() } } catch { }
                        try { if ($null -ne $discoveryRoot) { $discoveryRoot.Dispose() } } catch { }
                    }
                }

                # La session Windows continue d'utiliser LDAP.Protocols avec
                # Negotiate, puisqu'aucun mot de passe explicite n'est fourni.
                $isFullyQualified = ([string]$serverName).Contains(".")
                $identifier = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier -ArgumentList @([string]$serverName,389,$isFullyQualified,$false)
                $connection = New-Object System.DirectoryServices.Protocols.LdapConnection -ArgumentList @($identifier)
                $connection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
                $connection.Timeout = [TimeSpan]::FromSeconds($perServerTimeout)
                $connection.SessionOptions.ProtocolVersion = 3
                try { $connection.SessionOptions.Signing = $true } catch { }
                try { $connection.SessionOptions.Sealing = $true } catch { }
                try { $connection.Bind() }
                catch [System.DirectoryServices.Protocols.LdapException] {
                    $ldapCode = 0
                    try { $ldapCode = [int]$_.Exception.ErrorCode } catch { }
                    if ($ldapCode -eq 49) {
                        # Refus d identite : inutile et dangereux d insister
                        # sur les autres controleurs, ils repondront pareil et
                        # chaque essai rapproche du verrouillage du compte.
                        $watch.Stop()
                        $detail = Format-LdapError -ErrorRecord $_ -ServerName $serverName
                        Set-AuthProgress -Stage "Termine" -Detail $detail
                        return New-AuthResult -Success $false -AuthMode $(if($useCurrentCredentials){"Windows"}else{"Explicit"}) -AuthMethod "LDAP.Protocols.Negotiate" -Error $detail -ErrorCategory "Credentials" -Server $serverName -Attempts ($attempt) -DurationMs $watch.ElapsedMilliseconds
                    }
                    throw
                }

                $rootRequest = [System.DirectoryServices.Protocols.SearchRequest]::new(
                    "",
                    "(objectClass=*)",
                    [System.DirectoryServices.Protocols.SearchScope]::Base,
                    [string[]]@("defaultNamingContext","rootDomainNamingContext","configurationNamingContext","dnsHostName")
                )
                $rootResponse = [System.DirectoryServices.Protocols.SearchResponse]$connection.SendRequest($rootRequest)
                if ($rootResponse.Entries.Count -lt 1) { throw "RootDSE ne retourne aucune entree." }
                $rootEntry = $rootResponse.Entries[0]
                $detectedBase = Get-LdapAttributeFirst -Entry $rootEntry -Name "defaultNamingContext"
                if ([string]::IsNullOrWhiteSpace($detectedBase)) { throw "RootDSE ne retourne aucun defaultNamingContext." }
                $configurationNc = Get-LdapAttributeFirst -Entry $rootEntry -Name "configurationNamingContext"
                $detectedDc = Get-LdapAttributeFirst -Entry $rootEntry -Name "dnsHostName"
                $effectiveBase = if ([string]::IsNullOrWhiteSpace($configuredBase)) { $detectedBase } else { $configuredBase }

                $baseRequest = [System.DirectoryServices.Protocols.SearchRequest]::new(
                    $effectiveBase,
                    "(objectClass=*)",
                    [System.DirectoryServices.Protocols.SearchScope]::Base,
                    [string[]]@("distinguishedName")
                )
                $baseResponse = [System.DirectoryServices.Protocols.SearchResponse]$connection.SendRequest($baseRequest)
                if ($baseResponse.Entries.Count -lt 1) { throw "La base LDAP '$effectiveBase' est introuvable ou illisible." }

                $detectedDomain = Convert-AuthNamingContextToDns -NamingContext $detectedBase
                if ([string]::IsNullOrWhiteSpace($detectedDomain)) { $detectedDomain = $domainHint }
                $detectedNetbios = Get-AuthNetbiosName -Connection $connection -ConfigurationNamingContext $configurationNc -DefaultNamingContext $detectedBase
                if ([string]::IsNullOrWhiteSpace($detectedNetbios)) { $detectedNetbios = $netbiosHint }
                $selectedServer = if ([string]::IsNullOrWhiteSpace($detectedDc)) { [string]$serverName } else { $detectedDc }
                $bindIdentity = if ($useCurrentCredentials) {
                    try { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { "Session Windows" }
                }
                else { [string]$Request.Credential.UserName }

                Set-AuthProgress -Stage "Termine" -Detail "Contexte AD valide sur $selectedServer"
                $watch.Stop()
                return New-AuthResult -Success $true -BindUser $bindIdentity -AuthMode $(if($useCurrentCredentials){"Windows"}else{"Explicit"}) -AuthMethod "LDAP.Protocols.Negotiate+RootDSE" -BaseDn $effectiveBase -Server $selectedServer -Domain $detectedDomain -Netbios $detectedNetbios -RootPath "LDAP://$selectedServer/$effectiveBase" -Attempts $attempt -DurationMs $watch.ElapsedMilliseconds
            }
            catch { $lastError = Format-LdapError -ErrorRecord $_ -ServerName ([string]$serverName) }
            finally { try { if ($null -ne $connection) { $connection.Dispose() } } catch { } }
        }

        $watch.Stop()
        return New-AuthResult -Success $false -AuthMode $(if($useCurrentCredentials){"Windows"}else{"Explicit"}) -AuthMethod "LDAP.Protocols.Negotiate+RootDSE" -Domain $domainHint -Netbios $netbiosHint -Error $lastError -ErrorCategory "DomainUnavailable" -Attempts $attempt -DurationMs $watch.ElapsedMilliseconds
    }
    catch {
        $watch.Stop()
        $serverForError = ""
        try { $serverForError = [string]$Request.ConfiguredServer } catch { }
        if([string]::IsNullOrWhiteSpace($serverForError)){ $serverForError = "Active Directory" }
        $friendly = Format-LdapError -ErrorRecord $_ -ServerName $serverForError
        $cat = if($friendly -match "(?i)identifiant|mot de passe|verrouill|desactiv|desactiv|expir"){"Credentials"}else{"Unhandled"}
        return New-AuthResult -Success $false -AuthMode $(if([bool]$Request.UseCurrentCredentials){"Windows"}else{"Explicit"}) -AuthMethod "LDAP.Protocols.Negotiate+RootDSE" -Error $friendly -ErrorCategory $cat -DurationMs $watch.ElapsedMilliseconds
    }

}