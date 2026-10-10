# D071-D080 : assistance des postes. Donnees fictives uniquement (domaine example.test, adresses de documentation).
$script:WsNow=[datetime]::SpecifyKind([datetime]'2026-03-10T12:00:00',[DateTimeKind]::Utc)
$script:WsSessions=[pscustomobject]@{Computer='PC-01';ObservedUtc='2026-03-10T12:00:00Z';Source='WTS, lecture a la demande';Identity='EX\support';Rows=@(
    [pscustomobject]@{Id=0;Station='Services';User='';Domain='';State='Deconnectee';Protocol='Console';Detail='Lecture WTS';LogonTicks=-1;IdleTicks=-1}
    [pscustomobject]@{Id=1;Station='Console';User='';Domain='';State='Connectee';Protocol='Console';Detail='Lecture WTS';LogonTicks=134176140000000000;IdleTicks=72000000000}
    [pscustomobject]@{Id=2;Station='RDP-Tcp#3';User='jdupont';Domain='EX';State='Active';Protocol='RDP';Detail='Lecture WTS';LogonTicks=134176140000000000;IdleTicks=3000000000}
    [pscustomobject]@{Id=65536;Station='RDP-Tcp';User='';Domain='';State='Ecoute';Protocol='Indetermine';Detail='Lecture WTS';LogonTicks=-1;IdleTicks=-1})}
$script:WsGpoA='aaaaaaaa-0000-4000-8000-00000000000a';$script:WsGpoB='bbbbbbbb-0000-4000-8000-00000000000b';$script:WsGpoC='cccccccc-0000-4000-8000-00000000000c'
$script:WsGpoD='dddddddd-0000-4000-8000-00000000000d';$script:WsGpoE='eeeeeeee-0000-4000-8000-00000000000e';$script:WsGpoF='ffffffff-0000-4000-8000-00000000000f'
$script:WsContainers=@(
    [pscustomobject]@{Dn='OU=Postes,OU=Siege,DC=example,DC=test';GpLink=('[LDAP://cn={'+$script:WsGpoA.ToUpperInvariant()+'},cn=policies,cn=system,DC=example,DC=test;0]');GpOptions=0;ReadStatus='OK'}
    [pscustomobject]@{Dn='OU=Siege,DC=example,DC=test';GpLink=('[LDAP://cn={'+$script:WsGpoB+'},cn=policies,cn=system,DC=example,DC=test;0]');GpOptions=0;ReadStatus='OK'}
    [pscustomobject]@{Dn='DC=example,DC=test';GpLink=('[LDAP://cn={'+$script:WsGpoC+'},cn=policies,cn=system,DC=example,DC=test;2][LDAP://cn={'+$script:WsGpoD+'},cn=policies,cn=system,DC=example,DC=test;1][LDAP://cn={'+$script:WsGpoF+'},cn=policies,cn=system,DC=example,DC=test;0]');GpOptions=0;ReadStatus='OK'})
$script:WsDsreg=@(
    '+----------------------------------------------------------------------+'
    '| Device State                                                         |'
    '+----------------------------------------------------------------------+'
    ''
    '             AzureAdJoined : YES'
    '          EnterpriseJoined : NO'
    '              DomainJoined : YES'
    '                DomainName : EXAMPLE'
    '               Device Name : PC-01.example.test'
    ''
    '+----------------------------------------------------------------------+'
    '| Device Details                                                       |'
    '+----------------------------------------------------------------------+'
    ''
    '                  DeviceId : 00000000-0000-0000-0000-000000000000'
    '          DeviceAuthStatus : SUCCESS'
    ''
    '+----------------------------------------------------------------------+'
    '| Tenant Details                                                       |'
    '+----------------------------------------------------------------------+'
    ''
    '                TenantName : Exemple'
    ''
    '+----------------------------------------------------------------------+'
    '| User State                                                           |'
    '+----------------------------------------------------------------------+'
    ''
    '                    NgcSet : NO'
    '           WorkplaceJoined : NO'
    ''
    '+----------------------------------------------------------------------+'
    '| SSO State                                                            |'
    '+----------------------------------------------------------------------+'
    ''
    '                AzureAdPrt : YES'
    '      AzureAdPrtUpdateTime : 2026-03-10 08:00:00.000 UTC'
    ''
    '+----------------------------------------------------------------------+'
    '| Diagnostic Data                                                      |'
    '+----------------------------------------------------------------------+'
    ''
    '    Executing Account Name : EXAMPLE\jdupont, jdupont@example.test'
) -join "`r`n"
$script:WsPcA=[pscustomobject]@{Name='PC-01$';DnsHostName='pc-01.example.test';Guid='3a760e2f-315a-4155-a1d0-26a319a64cf2'}
$script:WsContract='{"Schema":"DomeniaSuiteContract/1","Tool":"Pesto","Version":"2.1","Context":{"ComputerName":"--computer","UserLogin":"--user"}}'

# ---------------------------------------------------------------- D071
Test-Case 'D071' 'Cinq controles bornes et cout annonce' {
    $p=Get-DomeniaQuickDiagPlan
    Assert-Equal 5 $p.CheckCount;Assert-Equal 5 @($p.Checks).Count
    Assert-Equal 'System|LastBoot|DiskC|Ports|Services' ((@($p.Checks)|ForEach-Object{$_.Id}) -join '|')
    $sum=0
    foreach($c in @($p.Checks)){Assert-True ([int]$c.TimeoutSeconds -gt 0) ('Delai absent : '+$c.Id);$sum+=[int]$c.TimeoutSeconds}
    Assert-Equal $sum $p.BudgetSeconds;Assert-True ($p.BudgetSeconds -le 20) 'Budget superieur a 20 s'
    Assert-Equal '5 contrôles, 20 s au plus' $p.CostText
    Assert-Equal '135,445,5985' (@(@($p.Checks)[3].Ports) -join ',')
    Assert-True ((@(@($p.Checks)[4].Services) -join ',') -match 'WinRM')
    Assert-False $p.Intrusive;Assert-Equal 'ExplicitRun' $p.Trigger
}
Test-Case 'D071' 'Ouvrir une liste ne lance pas le diagnostic' {
    foreach($t in @('ListOpened','Selection','TabOpened','Refresh','Scroll','','explicitrun')){Assert-False (Test-DomeniaQuickDiagAllowed $t 1).Allowed ('Declencheur accepte : '+$t)}
    Assert-True (Test-DomeniaQuickDiagAllowed 'ExplicitRun' 1).Allowed
    Assert-False (Test-DomeniaQuickDiagAllowed 'ExplicitRun' 12).Allowed 'Aucun diagnostic collectif'
}
Test-Case 'D071' 'Le retour brut devient des faits ; refus et echec ne sont pas des constats' {
    $raw=[pscustomobject]@{Computer='PC-01';ElapsedMs=8000;Checks=[pscustomobject]@{
        System=[pscustomobject]@{Status='OK';Caption='Microsoft Windows 11 Entreprise';Version='10.0.26100'}
        LastBoot=[pscustomobject]@{Status='OK';LastBootUtc=$script:WsNow.AddDays(-3)}
        DiskC=[pscustomobject]@{Status='OK';FreeBytes=5GB;SizeBytes=100GB}
        Ports=[pscustomobject]@{Status='AccessDenied'}
        Services=[pscustomobject]@{Status='Timeout';Detail='Delai CIM'}}}
    $r=ConvertTo-DomeniaQuickDiagFacts $raw $script:WsNow -Reader 'EX\support'
    $facts=@($r.Facts)
    Assert-Equal 5 $facts.Count
    Assert-Equal 'Constate' $facts[0].Etat;Assert-True ($facts[0].Valeur -match '26100')
    Assert-True ($facts[1].Valeur -match '3 j 0 h')
    Assert-Equal 'Constate' $facts[2].Etat;Assert-True ($facts[2].Hypothese -match '10 %') 'Moins de 10 % libres signale'
    Assert-Equal 'Refuse' $facts[3].Etat;Assert-Equal 'Indisponible' $facts[4].Etat;Assert-True ($facts[4].Valeur -match 'Delai CIM')
    Assert-Equal 'EX\support' $facts[0].Lecteur
    Assert-False $r.Complete;Assert-Equal 3 $r.Counts['Constate'];Assert-False $r.Overrun
    Assert-True ($r.Summary -match '1 refus')
}
Test-Case 'D071' 'Seuls les controles prevus deviennent des faits ; le depassement est signale' {
    $raw=[pscustomobject]@{ElapsedMs=25000;Checks=@{System=@{Status='OK';Caption='W';Version='1'};Inventaire=@{Status='OK'};Logiciels=@{Status='OK'};Ports=@{Status='OK';Results=@(@{Port=135;State='Open'},@{Port=445;State='Closed'})};Services=@{Status='OK';Results=@()}}}
    $r=ConvertTo-DomeniaQuickDiagFacts $raw $script:WsNow
    $facts=@($r.Facts)
    Assert-Equal 5 $facts.Count 'Les entrees hors plan sont ignorees'
    Assert-True $r.Overrun;Assert-True ($r.DurationText -match 'Budget d')
    Assert-Equal 'Inconnu' $facts[1].Etat 'Controle absent du retour : non execute';Assert-True ($facts[1].Valeur -match '^Non ex')
    Assert-True (($facts[3].Valeur -match '135 ouvert') -and ($facts[3].Valeur -match '445 ferm') -and ($facts[3].Valeur -match '5985 non test'))
    Assert-Equal 'Inconnu' $facts[4].Etat 'Aucun service lu : pas de constat'
    Assert-False (ConvertTo-DomeniaQuickDiagFacts ([pscustomobject]@{ElapsedMs=19000;Checks=@{}}) $script:WsNow).Overrun
    Assert-Equal 5 @((ConvertTo-DomeniaQuickDiagFacts $null $script:WsNow).Facts|Where-Object{$_.Etat -eq 'Inconnu'}).Count 'Rien lu : rien de constate'
}

# ---------------------------------------------------------------- D072
Test-Case 'D072' 'Console vide ne signifie pas absence de session RDP' {
    $v=ConvertTo-DomeniaSessionView $script:WsSessions
    Assert-False $v.ConsoleOccupied;Assert-Equal 1 $v.RdpSessions;Assert-Equal 1 $v.UserSessions;Assert-Equal 3 $v.SystemSessions
    Assert-True ($v.EmptyText -match 'ne signifie pas absence de session RDP')
    $console=Get-DomeniaSessionEmptyText -ReadStatus OK -Coverage ConsoleOnly -ConsoleOccupied $false
    Assert-True ($console -match 'ne signifie pas absence de session RDP');Assert-False ($console -match '^Aucune session')
}
Test-Case 'D072' 'Session, utilisateur, etat, protocole et source affiches' {
    $row=@((ConvertTo-DomeniaSessionView $script:WsSessions).Rows)[0]
    Assert-Equal '2 (RDP-Tcp#3)' $row.Session;Assert-Equal 'EX\jdupont' $row.Utilisateur;Assert-Equal 'Active' $row.Etat;Assert-Equal 'RDP' $row.Protocole
    Assert-True ($row.Source -match '^WTS')
}
Test-Case 'D072' 'Refus de lecture : aucune conclusion ; consultation sans deconnexion' {
    $v=ConvertTo-DomeniaSessionView $null 'AccessDenied'
    Assert-Equal 'Refuse' $v.ReadState;Assert-Equal 0 @($v.Rows).Count;Assert-True ($v.EmptyText -match 'aucune conclusion')
    Assert-False ($v.EmptyText -match 'Aucune session')
    Assert-Equal 'Indisponible' (ConvertTo-DomeniaSessionView $null 'Timeout').ReadState
    Assert-Equal 'Refuse' (ConvertTo-DomeniaSessionView $null 'CredentialsRejected').ReadState
    foreach($view in @($v,(ConvertTo-DomeniaSessionView $script:WsSessions))){
        Assert-Equal 'Relire' (@($view.Actions) -join '|') 'Seule action : relire'
        Assert-True ($view.StatusText -match 'aucune d')
    }
}
Test-Case 'D072' 'Compte de session illisible : lecture partielle, pas une absence' {
    $r=[pscustomobject]@{Computer='PC-01';Rows=@([pscustomobject]@{Id=3;Station='RDP-Tcp#5';User='';Domain='';State='Active';Protocol='RDP';Detail='Information partielle, code Windows 5'})}
    $v=ConvertTo-DomeniaSessionView $r
    Assert-Equal 1 $v.UnreadSessions;Assert-Equal 1 @($v.Rows).Count;Assert-Equal 'Compte non lu' @($v.Rows)[0].Utilisateur
    Assert-True ($v.EmptyText -match 'partielle');Assert-False ($v.EmptyText -match 'Aucune session')
    $noRows=ConvertTo-DomeniaSessionView ([pscustomobject]@{Computer='PC-01';Source='WTS'})
    Assert-Equal 'Inconnu' $noRows.ReadState 'Reponse sans liste : pas une liste vide';Assert-False ($noRows.EmptyText -match 'Aucune session')
}
Test-Case 'D072' 'Liste nulle, lecture partielle ou statut inconnu : jamais une absence ni une lecture non demandee' {
    foreach($r in @([pscustomobject]@{Computer='PC-01';Rows=$null},@{Computer='PC-01';Rows=$null},[pscustomobject]@{Computer='PC-01';Rows='texte'})){
        $v=ConvertTo-DomeniaSessionView $r
        Assert-Equal 'Inconnu' $v.ReadState 'Rows nul : reponse incomplete';Assert-Equal 0 @($v.Rows).Count
        Assert-False ($v.EmptyText -match 'Aucune session') $v.EmptyText;Assert-False ($v.EmptyText -match 'bouton Lire') $v.EmptyText
        Assert-True ($v.EmptyText -match 'aucune conclusion') $v.EmptyText
    }
    $empty=ConvertTo-DomeniaSessionView ([pscustomobject]@{Computer='PC-01';Rows=@()})
    Assert-Equal 'Constate' $empty.ReadState 'Liste vraiment vide : constat';Assert-True ($empty.EmptyText -match '^Aucune session')
    $partialEmpty=ConvertTo-DomeniaSessionView ([pscustomobject]@{ReadStatus='PARTIEL';Computer='PC-01';Rows=@()})
    Assert-True $partialEmpty.Partial;Assert-True ($partialEmpty.EmptyText -match 'partielle') $partialEmpty.EmptyText
    Assert-False ($partialEmpty.EmptyText -match '(?i)aucune session|non lues|bouton Lire') $partialEmpty.EmptyText
    $partialRows=ConvertTo-DomeniaSessionView ([pscustomobject]@{ReadStatus='PARTIEL';Computer='PC-01';Rows=@([pscustomobject]@{Id=2;Station='RDP-Tcp#3';User='jdupont';Domain='EX';State='Active';Protocol='RDP'})})
    Assert-Equal 1 @($partialRows.Rows).Count 'Les sessions lues restent affichees';Assert-True ($partialRows.EmptyText -match 'partielle')
    $odd=ConvertTo-DomeniaSessionView ([pscustomobject]@{ReadStatus='ETRANGE';Computer='PC-01';Rows=@()})
    Assert-Equal 'Inconnu' $odd.ReadState;Assert-True ($odd.EmptyText -match 'non reconnu') $odd.EmptyText;Assert-False ($odd.EmptyText -match 'bouton Lire')
    Assert-True ((ConvertTo-DomeniaSessionView $null).EmptyText -match 'bouton Lire') 'Non demande : seul cas du bouton Lire'
}

Test-Case 'UX-39' 'Sessions : heure locale, duree d inactivite, compte nu pour ouvrir la fiche' {
    $e=[string][char]0x00E9;$a=[string][char]0x00E0
    $v=ConvertTo-DomeniaSessionView $script:WsSessions
    $row=@($v.Rows)[0]
    $lu=ConvertTo-DomeniaUtcDate '2026-03-10T12:00:00Z'
    $ouverte=[datetime]::FromFileTimeUtc(134176140000000000).ToLocalTime()
    # La comparaison se fait sur le fuseau de la machine qui court le banc : ce que le banc attend est ce que
    # la vue calcule, pas une heure de Paris ecrite en dur qui echouerait sur une machine d un autre fuseau.
    $attendu=if($ouverte.Date -eq $lu.ToLocalTime().Date){$ouverte.ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture)}else{$ouverte.ToString('dd/MM HH:mm',[Globalization.CultureInfo]::InvariantCulture)}
    Assert-Equal $attendu $row.Ouverte 'Ouverte a rend l heure locale de la machine qui affiche'
    Assert-True ($row.Ouverte -notmatch 'T\d\d:') 'Ni ISO ni UTC dans la grille'
    Assert-Equal '5 min' $row.Inactive 'WTSIdleTime est une duree, pas une date'
    Assert-Equal 'jdupont' $row.User 'Le compte nu, seul format que connait le filtre AD'
    Assert-Equal '' (Get-DomeniaSessionOpenedText -Ticks -1 -Reference $lu) 'Une horloge que le poste ne rend pas reste vide'
    Assert-Equal '' (Get-DomeniaSessionIdleText -Ticks 0) 'Zero tick n est pas une inactivite de zero seconde'
    Assert-Equal '2 h' (Get-DomeniaSessionIdleText -Ticks 72000000000) 'Deux heures d inactivite'
    Assert-True ($v.StatusText.StartsWith('Lu '+$a+' ')) ('L etat commence par l heure locale : '+$v.StatusText)
    Assert-True ($v.StatusText -match ('masqu'+$e+'e')) 'Les lignes sans compte masquees sont annoncees'
    Assert-True ($v.StatusText -notmatch 'T12:00:00') 'L horodatage ISO n est plus affiche'
    Assert-True ($v.StatusText -notmatch 'WTS') 'Le jargon du collecteur ne remonte plus a l operateur'
    Assert-Equal 'jdupont' (Get-DomeniaSessionAccountName -Row $row) 'Le compte de la ligne, pret pour la fiche'
    Assert-Equal '' (Get-DomeniaSessionAccountName -Row ([pscustomobject]@{Utilisateur='Compte non lu'})) 'Un compte non lu n a pas de fiche'
    Assert-Equal '' (Get-DomeniaSessionAccountName -Row $null) 'Pas de ligne : pas de compte'
}

# ---------------------------------------------------------------- D073
Test-Case 'D073' 'Sources de desinstallation 64 et 32 bits ; categories non couvertes indiquees' {
    $s=Get-DomeniaSoftwareSources
    $byId=@{};foreach($row in @($s.Sources)){$byId[$row.Id]=$row}
    Assert-True ($byId['Uninstall64'].Incluse -and $byId['Uninstall32'].Incluse)
    Assert-True ($byId['Uninstall32'].Emplacement -match 'WOW6432Node');Assert-False ($byId['Uninstall64'].Emplacement -match 'WOW6432Node')
    Assert-False $byId['PerUser'].Couverte;Assert-False $byId['Appx'].Couverte
    Assert-True ((@($s.Uncovered) -join '|') -match 'par utilisateur');Assert-True ((@($s.Uncovered) -join '|') -match 'Appx/MSIX')
    Assert-True ($s.CoverageText -match '^Non couvert')
    Assert-Equal 'Win32_Product' @($s.Excluded)[0].Id
    Assert-False (((@($s.Sources)|ForEach-Object{$_.Emplacement}) -join '|') -match '(?i)win32_product')
    Assert-Equal 1 @((Get-DomeniaSoftwareSources -Included @('Uninstall64','Win32_Product')).Refused).Count 'Win32_Product n est pas une source'
}
Test-Case 'D073' 'Une source refusee ou partielle n est pas couverte' {
    $s=Get-DomeniaSoftwareSources -Included @('Uninstall64','Uninstall32','PerUser') -Outcomes @{Uninstall64='OK';Uninstall32='REFUSE';PerUser='PARTIEL'}
    $byId=@{};foreach($row in @($s.Sources)){$byId[$row.Id]=$row}
    Assert-True $byId['Uninstall64'].Couverte;Assert-False $byId['Uninstall32'].Couverte;Assert-False $byId['PerUser'].Couverte
    Assert-Equal 'Lecture partielle' $byId['PerUser'].Etat
    Assert-True ((@($s.Uncovered) -join '|') -match 'lecture refus')
    Assert-True @((Get-DomeniaSoftwareSources -Outcomes @{Uninstall64='VIDE';Uninstall32='OK'}).Sources)[0].Couverte 'Lu sans resultat reste couvert'
    Assert-False @((Get-DomeniaSoftwareSources -Outcomes @{Uninstall64='OK'}).Sources)[1].Couverte 'Source non lue : non couverte'
}
Test-Case 'D073' 'Win32_Product refuse dans un code d inventaire, meme dans un code de worker' {
    $here="function Get-InvCode {`nreturn @'`nGet-CimInstance -ClassName Win32_Product | Select-Object Name`n'@`n}"
    $hereTwo="return @'`n`$rows=@()`nforeach(`$p in @(Get-WmiObject -Query 'SELECT * FROM Win32_Product')){`$rows+=`$p.Name}`n'@"
    $unsafe=@('Get-CimInstance -ClassName Win32_Product','Get-WmiObject Win32_Product','Get-CimInstance -Query "SELECT Name FROM Win32_Product"','[wmiclass]''root\cimv2:Win32_Product''','$c=''Win32_Product'';Get-CimInstance -ClassName $c','msiexec /fa produit.msi',$here,$hereTwo,'if (')
    foreach($code in $unsafe){$check=Test-DomeniaInventoryCodeSafe $code;Assert-False $check.Safe ('Accepte : '+$code);Assert-True (@($check.Findings).Count -gt 0)}
    Assert-True ((@((Test-DomeniaInventoryCodeSafe $here).Findings) -join ' ') -match 'Classe Win32_Product')
    $guardHere="return @'`n"+'if ([string]$Payload.ClassName -ieq ''Win32_Product'') { throw ''bloque'' }'+"`n"+'Get-ItemProperty -Path ''HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'''+"`n'@"
    $safe=@('if ($ClassName -ieq ''Win32_Product'') { throw ''Classe bloquee'' }','if ($c -in @(''Win32_Product'')) { throw ''x'' }','Get-ItemProperty -Path ''HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*''',$guardHere,'msiexec /i produit.msi /qn')
    foreach($code in $safe){$check=Test-DomeniaInventoryCodeSafe $code;Assert-True $check.Safe ('Refuse : '+$code+' : '+(@($check.Findings) -join ', '))}
}
Test-Case 'D073' 'Classes parentes et autres classes du fournisseur MSI refusees ; garde limitee a une condition' {
    $unsafe=@('Get-CimInstance -ClassName CIM_Product | Select-Object Name','Get-WmiObject -Query "SELECT * FROM CIM_Product"','Get-CimInstance Win32_SoftwareFeature','Get-CimInstance -ClassName Win32_SoftwareElement',
        '[wmi]''root\cimv2:Win32_SoftwareFeature.Name="x"''','Get-WmiObject -Query ''ASSOCIATORS OF {Win32_Product.IdentifyingNumber="1"}''','Register-CimIndicationEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 5 WHERE TargetInstance ISA ''Win32_Product''"',
        'Get-CimInstance -ClassName CIM_LogicalElement',"Get-CimInstance -ClassName (@('Win32_Product') -ne '')[0]",'$x=(''Win32_Product'' -ne '''');Get-CimInstance $x','Get-CimInstance -ClassName @(''Win32_Product'' -like ''W*'')',
        'foreach ($n in (@(''CIM_Product'') -ne '''')) { Get-CimInstance $n }',"return @'`nGet-CimInstance -ClassName cim_product`n'@")
    foreach($code in $unsafe){$check=Test-DomeniaInventoryCodeSafe $code;Assert-False $check.Safe ('Accepte : '+$code)}
    Assert-True ((@((Test-DomeniaInventoryCodeSafe 'Get-CimInstance -ClassName cim_product').Findings) -join ' ') -match 'Classe CIM_Product') 'Nom canonique dans le constat'
    $safe=@('Get-CimInstance -ClassName Win32_ComputerSystemProduct','Get-CimInstance Win32_InstalledWin32Program','Get-CimInstance Win32_QuickFixEngineering','Get-CimInstance Win32_Service',
        'while ($name -ne ''CIM_Product'') { $name = Get-Next }','if (-not ($c -ieq ''Win32_SoftwareFeature'') -and $ok) { Get-CimInstance $c }','if ($a) { } elseif ($c -eq ''Win32_Product'') { throw ''x'' }',
        'do { $c = Get-Next } until ($c -eq ''Win32_Product'')')
    foreach($code in $safe){$check=Test-DomeniaInventoryCodeSafe $code;Assert-True $check.Safe ('Refuse : '+$code+' : '+(@($check.Findings) -join ', '))}
    $names=@(Get-DomeniaMsiProviderClassNames)
    Assert-Equal 'Win32_Product' $names[0];Assert-Equal 88 $names.Count
    foreach($n in @('Win32_Product','cim_product','root\cimv2:Win32_SoftwareFeature','\\pc\root\cimv2:Win32_Product.IdentifyingNumber="1"','Win32_PatchPackage','CIM_Service')){Assert-True (Test-DomeniaMsiProviderClass $n) ('Classe MSI non reconnue : '+$n)}
    foreach($n in @('Win32_ComputerSystemProduct','Win32_Service','Win32_OperatingSystem','','Win32_ProductX')){Assert-False (Test-DomeniaMsiProviderClass $n) ('Classe hors MSI refusee : '+$n)}
    Assert-True ((@((Get-DomeniaSoftwareSources).Excluded)|ForEach-Object{$_.Reason}) -join ' ') -match '88 classes'
}
Test-Case 'D073' 'Inventaire existant : correspondance des acces, SCCM ne couvre que les programmes 32 bits' {
    $access=@([pscustomobject]@{Category='Joignabilite';Status='OK'},[pscustomobject]@{Category='Connexion CIM';Status='OK'},
        [pscustomobject]@{Category='Machine';Status='OK';Method='CIM/DCOM';Detail='Inventaire SCCM present, une seule requete.'},
        [pscustomobject]@{Category='Utilisateur';Status='INDISPONIBLE'},[pscustomobject]@{Category='Store';Status='OK'},[pscustomobject]@{Category='Autre chose';Status='OK'})
    $m=ConvertFrom-DomeniaSoftwareAccess $access
    Assert-Equal 'Sccm|PerUser|Appx' (@($m.Included) -join '|');Assert-Equal 2 @($m.Transport).Count;Assert-Equal 'Autre chose' (@($m.Unmapped) -join '|')
    $s=Get-DomeniaSoftwareSources -Included $m.Included -Outcomes $m.Outcomes
    $u=@($s.Uncovered) -join '|'
    Assert-True ($u -match 'Programmes 64 bits') 'SCCM seul : 64 bits non couverts';Assert-False ($u -match 'Programmes 32 bits') 'SCCM couvre les 32 bits'
    Assert-True ($u -match 'par utilisateur \(lecture impossible\)');Assert-False ($u -match 'Appx')
    $c=@{};foreach($row in @($s.Categories)){$c[$row.Categorie]=$row}
    Assert-False $c['Programmes 64 bits (machine)'].Couverte;Assert-True $c['Programmes 32 bits (machine)'].Couverte;Assert-Equal 'Sccm' (@($c['Programmes 32 bits (machine)'].Sources) -join '|')
    $byId=@{};foreach($row in @($s.Sources)){$byId[$row.Id]=$row}
    Assert-True ($byId['Sccm'].Limite -match '32 bits');Assert-False ($byId['Sccm'].Emplacement -match '(?i)win32_product')
    $reg=ConvertFrom-DomeniaSoftwareAccess @([pscustomobject]@{Category='Machine';Status='PARTIEL';Detail='Lecture arretee apres 400 cles.'},[pscustomobject]@{Category='Machine';Status='OK';Detail='Un seul aller-retour pour les deux ruches.'})
    Assert-Equal 'Uninstall64|Uninstall32' (@($reg.Included) -join '|');Assert-Equal 'PARTIEL' $reg.Outcomes['Uninstall64'] 'Deux lignes : la moins concluante reste'
    $r=Get-DomeniaSoftwareSources -Included $reg.Included -Outcomes $reg.Outcomes
    Assert-True ((@($r.Uncovered) -join '|') -match '64 bits \(machine\) \(lecture partielle\)')
    Assert-Equal 'Sccm' (@((ConvertFrom-DomeniaSoftwareAccess @([pscustomobject]@{Category='Machine';Status='OK';Detail='x'}) -MachineSource 'SCCM').Included) -join '|')
    Assert-Equal 0 @((ConvertFrom-DomeniaSoftwareAccess @([pscustomobject]@{Category='Connexion CIM';Status='OK'})).Included).Count 'Une etape de transport ne couvre rien'
    $default=Get-DomeniaSoftwareSources
    Assert-False ((@($default.Uncovered) -join '|') -match 'SCCM|32 bits') 'Source SCCM non demandee : pas une categorie manquante'
}
Test-Case 'D073' 'Le code livre ne lit jamais Win32_Product ni une classe du fournisseur MSI' {
    $files=@(Get-Item -LiteralPath (Join-Path $wad 'Domenia-Core.ps1'))+@(Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File)
    Assert-True ($files.Count -gt 10);Assert-Equal 1 @($files|Where-Object{$_.Name -eq 'Domenia-Workstation.Model.ps1'}).Count 'Ce module est analyse lui aussi'
    foreach($file in $files){$check=Test-DomeniaInventoryCodeSafe ([IO.File]::ReadAllText($file.FullName));Assert-True $check.Safe ($file.Name+' : '+(@($check.Findings) -join ', '))}
}

# ---------------------------------------------------------------- D074
Test-Case 'D074' 'Prereglages : fournisseurs et identifiants utiles' {
    $p=@{};foreach($x in @(Get-DomeniaEventPresets)){$p[$x.Id]=$x}
    Assert-Equal 5 $p.Count
    Assert-Equal '6005,6006,6008,41,1074' (@($p['Startup'].EventIds) -join ',')
    Assert-Equal '1000,1001' (@($p['Crash'].EventIds) -join ',')
    Assert-Equal '7,11,51,153' (@($p['Disk'].EventIds) -join ',')
    Assert-Equal '1085,1125,7016' (@($p['Policy'].EventIds) -join ',')
    Assert-Equal '19,20,43' (@($p['Updates'].EventIds) -join ',')
    foreach($x in @($p.Values)){Assert-True (@($x.Providers).Count -gt 0) ('Fournisseur absent : '+$x.Id);Assert-True (@($x.LogName).Count -gt 0) ('Journal absent : '+$x.Id)}
}
Test-Case 'D074' 'Fenetre et volume bornes' {
    $q=New-DomeniaEventQuery 'Disk' $script:WsNow 100000 5000 'PC-01'
    Assert-Equal 720 $q.WindowHours;Assert-Equal 200 $q.MaxEvents;Assert-True $q.Clamped
    Assert-Equal ($script:WsNow.AddHours(-720)) $q.StartTimeUtc;Assert-Equal $script:WsNow $q.EndTimeUtc
    Assert-Equal '7,11,51,153' (@($q.Filter['Id']) -join ',');Assert-Equal 'disk' (@($q.Filter['ProviderName']) -join ',');Assert-Equal 'System' (@($q.Filter['LogName']) -join ',')
    $small=New-DomeniaEventQuery 'Startup' $script:WsNow 0 0;Assert-Equal 1 $small.WindowHours;Assert-Equal 1 $small.MaxEvents
    $d=New-DomeniaEventQuery 'Crash' $script:WsNow;Assert-Equal 72 $d.WindowHours;Assert-Equal 50 $d.MaxEvents;Assert-False $d.Clamped
    Assert-Throws {New-DomeniaEventQuery 'Tout' $script:WsNow} 'Pas de requete sans prereglage'
}
Test-Case 'D074' 'Un refus de lecture n est pas un constat sain' {
    $q=New-DomeniaEventQuery 'Startup' $script:WsNow -Computer 'PC-01'
    $denied=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='AccessDenied'}) $q -NowUtc $script:WsNow
    Assert-False $denied.NoEventsConfirmed;Assert-Equal 'Refuse' @($denied.Facts)[0].Etat;Assert-Equal 0 @($denied.Rows).Count
    Assert-True (@($denied.Facts)[0].Limite -match 'aucun constat sain')
    Assert-Equal 'Indisponible' @((ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='Timeout'}) $q -NowUtc $script:WsNow).Facts)[0].Etat
    Assert-False (ConvertTo-DomeniaEventFacts $null $q -NowUtc $script:WsNow).NoEventsConfirmed
    $noList=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='OK'}) $q -NowUtc $script:WsNow
    Assert-False $noList.NoEventsConfirmed 'Reponse sans liste : pas d absence';Assert-Equal 'Inconnu' @($noList.Facts)[0].Etat
    $empty=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='OK';Events=@()}) $q -NowUtc $script:WsNow
    Assert-True $empty.NoEventsConfirmed;Assert-Equal 'Constate' @($empty.Facts)[0].Etat
}
Test-Case 'D074' 'Liste nulle, lecture partielle ou statut inconnu : aucune absence constatee' {
    $q=New-DomeniaEventQuery 'Startup' $script:WsNow -Computer 'PC-01'
    foreach($r in @([pscustomobject]@{ReadStatus='OK';Events=$null},@{ReadStatus='OK';Events=$null},[pscustomobject]@{Events=$null},[pscustomobject]@{ReadStatus='OK';Events='aucun'})){
        $f=ConvertTo-DomeniaEventFacts $r $q -NowUtc $script:WsNow
        Assert-False $f.NoEventsConfirmed 'Events nul : silence d une erreur possible';Assert-Equal 'Inconnu' @($f.Facts)[0].Etat;Assert-Equal 'Inconnu' $f.ReadState
        Assert-False (@($f.Facts)[0].Valeur -match '^Aucun') @($f.Facts)[0].Valeur
    }
    $partial=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='PARTIEL';Events=@()}) $q -NowUtc $script:WsNow
    Assert-False $partial.NoEventsConfirmed;Assert-Equal 'Inconnu' @($partial.Facts)[0].Etat;Assert-True $partial.Partial
    Assert-False (@($partial.Facts)[0].Valeur -match 'Non demand') 'La lecture a eu lieu';Assert-True (@($partial.Facts)[0].Limite -match 'partielle')
    $one=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='PARTIEL';Events=@([pscustomobject]@{Id=41;ProviderName='Microsoft-Windows-Kernel-Power';MachineName='PC-01';TimeCreatedUtc=$script:WsNow.AddHours(-1)})}) $q -NowUtc $script:WsNow
    Assert-Equal 1 @($one.Rows).Count 'Evenements lus affiches';Assert-True $one.Partial;Assert-True (@($one.Facts)[0].Limite -match 'incompl')
    $odd=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='ETRANGE';Events=@()}) $q -NowUtc $script:WsNow
    Assert-False $odd.NoEventsConfirmed;Assert-False (@($odd.Facts)[0].Valeur -match 'Non demand');Assert-True (@($odd.Facts)[0].Limite -match 'ETRANGE')
    Assert-True (@((ConvertTo-DomeniaEventFacts $null $q -NowUtc $script:WsNow).Facts)[0].Valeur -match 'Non demand') 'Seul le cas non demande le dit'
}
Test-Case 'D074' 'Evenements non attribuables : generaux ; correlation explicite a la cible' {
    $q=New-DomeniaEventQuery 'Crash' $script:WsNow -Computer 'PC-01'
    $events=@(
        [pscustomobject]@{Id=1000;ProviderName='Application Error';TimeCreatedUtc=$script:WsNow.AddHours(-1);MachineName='PC-01.example.test';UserId='S-1-5-21-1-2-3-1001';Message='a'}
        [pscustomobject]@{Id=1001;ProviderName='Windows Error Reporting';TimeCreatedUtc=$script:WsNow.AddHours(-2);MachineName='PC-99.example.test';UserId='';Message='b'}
        [pscustomobject]@{Id=1001;ProviderName='Windows Error Reporting';TimeCreatedUtc=$script:WsNow.AddHours(-3);MachineName='';UserId='S-1-5-21-1-2-3-1002';Message='c'}
        [pscustomobject]@{Id=4624;ProviderName='Microsoft-Windows-Security-Auditing';MachineName='PC-01';Message='hors prereglage'})
    $byMachine=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='OK';Events=$events}) $q -NowUtc $script:WsNow
    Assert-Equal 1 $byMachine.Attributed;Assert-Equal 2 $byMachine.General;Assert-Equal 1 $byMachine.Ignored;Assert-Equal 3 @($byMachine.Rows).Count
    Assert-Equal 'Cible' @($byMachine.Rows)[0].Attribution;Assert-True (@($byMachine.Rows)[1].Attribution -ne 'Cible');Assert-True (@($byMachine.Rows)[2].Attribution -ne 'Cible')
    $byUser=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='OK';Events=$events}) $q -UserSid 'S-1-5-21-1-2-3-1002' -NowUtc $script:WsNow
    Assert-Equal 1 $byUser.Attributed;Assert-Equal 'Cible' @($byUser.Rows)[2].Attribution;Assert-True (@($byUser.Rows)[0].Attribution -ne 'Cible') 'Evenement d un autre compte non attribue'
}
Test-Case 'D074' 'Volume plafonne : liste partielle, jamais une absence' {
    $q=New-DomeniaEventQuery 'Disk' $script:WsNow 24 2 'PC-01'
    $three=@(1..3|ForEach-Object{[pscustomobject]@{Id=7;ProviderName='disk';MachineName='PC-01';TimeCreatedUtc=$script:WsNow.AddMinutes(-$_)}})
    $r=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='OK';Events=$three}) $q -NowUtc $script:WsNow
    Assert-Equal 2 @($r.Rows).Count;Assert-True $r.Partial;Assert-True (@($r.Facts)[0].Limite -match 'partielle')
    $t=ConvertTo-DomeniaEventFacts ([pscustomobject]@{ReadStatus='OK';Events=@();Truncated=$true}) $q -NowUtc $script:WsNow
    Assert-False $t.NoEventsConfirmed;Assert-Equal 'Inconnu' @($t.Facts)[0].Etat
}

# ---------------------------------------------------------------- D075
Test-Case 'D075' 'Une GPO liee n est pas annoncee appliquee sans preuve du resultat' {
    $v=Resolve-DomeniaGpoView $script:WsContainers $null
    Assert-Equal 5 @($v.Rows).Count;Assert-False $v.AppliedProven
    foreach($row in @($v.Rows)){Assert-Equal 'Unproven' $row.Result $row.Guid;Assert-False ($row.Resultat -match '^Appliqu') $row.Guid;Assert-Equal 'Liens AD (gPLink) seulement' $row.Preuve}
    Assert-False (@($v.Facts)[1].Valeur -match 'appliqu') 'Aucun nombre de GPO appliquees sans RSoP'
    $refused=Resolve-DomeniaGpoView $script:WsContainers ([pscustomobject]@{ReadStatus='AccessDenied'})
    Assert-Equal 0 @($refused.Rows|Where-Object{$_.Result -eq 'Applied'}).Count;Assert-Equal 'Refuse' $refused.RsopState;Assert-Equal 'Refuse' @($refused.Facts)[1].Etat
    Assert-True (@($refused.Rows)[0].Resultat -match 'refus')
}
Test-Case 'D075' 'Liens AD et resultat RSoP restent distincts' {
    $rsop=[pscustomobject]@{ReadStatus='OK';ReadUtc=$script:WsNow;Gpos=@(
        [pscustomobject]@{GuidName=('{'+$script:WsGpoA.ToUpperInvariant()+'}');Name='Postes';AccessDenied=$false;FilterAllowed=$true;Enabled=$true}
        [pscustomobject]@{Id=('CN={'+$script:WsGpoC+'},CN=Policies,CN=System,DC=example,DC=test');Name='Domaine';AccessDenied=$false;FilterAllowed=$true;Enabled=$true}
        [pscustomobject]@{Guid=$script:WsGpoE;Name='Site';AccessDenied=$false;FilterAllowed=$true;Enabled=$true}
        [pscustomobject]@{Guid=$script:WsGpoB;Name='Siege';AccessDenied=$true;FilterAllowed=$true;Enabled=$true}
        [pscustomobject]@{Id='LocalGPO';GuidName='Local Group Policy';Name='Local Group Policy';AccessDenied=$false;FilterAllowed=$true;Enabled=$true});Links=@(
        [pscustomobject]@{Gpo=('CN={'+$script:WsGpoA.ToUpperInvariant()+'},CN=Policies,CN=System,DC=example,DC=test');Som='OU=Postes,OU=Siege,DC=example,DC=test';AppliedOrder=3}
        [pscustomobject]@{Gpo=('CN={'+$script:WsGpoC+'},CN=Policies,CN=System,DC=example,DC=test');Som='DC=example,DC=test';AppliedOrder=[uint32]1}
        [pscustomobject]@{Guid=$script:WsGpoE;Som='CN=Site,CN=Sites,CN=Configuration,DC=example,DC=test';AppliedOrder='2'}
        [pscustomobject]@{Gpo=('CN={'+$script:WsGpoB+'},CN=Policies,CN=System,DC=example,DC=test');Som='OU=Siege,DC=example,DC=test';AppliedOrder=0}
        [pscustomobject]@{Gpo='LocalGPO';Som='Local';AppliedOrder=0})}
    $v=Resolve-DomeniaGpoView $script:WsContainers $rsop
    $r=@{};foreach($row in @($v.Rows)){$r[$row.Guid]=$row}
    Assert-Equal 'Applied' $r[$script:WsGpoA].Result;Assert-Equal 'Filtered' $r[$script:WsGpoB].Result;Assert-Equal 'Applied' $r[$script:WsGpoC].Result
    Assert-Equal 'NotApplied' $r[$script:WsGpoD].Result 'Lien desactive absent du RSoP';Assert-Equal 'NotApplied' $r[$script:WsGpoF].Result 'Lien actif absent du RSoP'
    Assert-Equal 'Applied' $r[$script:WsGpoE].Result;Assert-True ($r[$script:WsGpoE].Lien -match 'Hors liens') 'Une GPO de site reste distincte des liens lus'
    Assert-True $v.AppliedProven;Assert-True (@($v.Facts)[1].Valeur -match '^3 GPO')
    Assert-True ($r[$script:WsGpoA].Preuve -match 'RSoP');Assert-True ($r[$script:WsGpoA].Resultat -match 'ordre d.application 3')
    Assert-Equal 6 @($v.Rows).Count 'La strategie locale sans GUID n ajoute pas de ligne'
}
Test-Case 'D075' 'Reponse RSoP incomplete ou vide : aucune GPO declaree absente ni appliquee' {
    $cases=@([pscustomobject]@{ReadStatus='OK'},[pscustomobject]@{ReadStatus='OK';Gpos=$null},@{ReadStatus='OK';Gpos=$null},[pscustomobject]@{ReadStatus='OK';Gpos='texte'},[pscustomobject]@{ReadStatus='OK';Gpos=@()},[pscustomobject]@{ReadStatus='OK';Gpos=@($null)},[pscustomobject]@{ReadStatus='PARTIEL';Gpos=@([pscustomobject]@{Guid=$script:WsGpoA})})
    foreach($rsop in $cases){
        $v=Resolve-DomeniaGpoView $script:WsContainers $rsop
        Assert-False $v.AppliedProven 'Reponse incomplete : rien de prouve';Assert-True ($v.RsopState -ne 'Constate')
        Assert-Equal 0 @($v.Rows|Where-Object{$_.Result -ne 'Unproven'}).Count 'Aucune GPO NotApplied ni Applied'
        Assert-Equal 0 @($v.Rows|Where-Object{$_.Etat -eq 'Constate'}).Count 'Aucune ligne constatee'
        Assert-False (@($v.Facts)[1].Valeur -match '^\d+ GPO') @($v.Facts)[1].Valeur;Assert-True (@($v.Facts)[1].Etat -ne 'Constate')
    }
    Assert-True (@((Resolve-DomeniaGpoView $script:WsContainers $cases[0]).Rows)[0].Resultat -match 'incompl')
    Assert-True (@((Resolve-DomeniaGpoView $script:WsContainers $cases[4]).Rows)[0].Resultat -match 'vide')
    Assert-True (@((Resolve-DomeniaGpoView $script:WsContainers $cases[6]).Rows)[0].Resultat -match 'partielle')
}
Test-Case 'D075' 'Drapeaux RSoP absents ou sans ordre d application : GPO non annoncee appliquee' {
    $g=$script:WsGpoA;$c=@($script:WsContainers[0]);$dn=('CN={'+$g+'},CN=Policies,CN=System,DC=example,DC=test')
    foreach($entry in @([pscustomobject]@{Guid=$g},[pscustomobject]@{Guid=$g;AccessDenied=$null;FilterAllowed=$null;Enabled=$null},[pscustomobject]@{Guid=$g;AccessDenied='peut-etre';FilterAllowed='';Enabled=$null},[pscustomobject]@{Guid=$g;AccessDenied=$false;FilterAllowed=$true;Enabled=$true})){
        $v=Resolve-DomeniaGpoView $c ([pscustomobject]@{ReadStatus='OK';Gpos=@($entry)})
        $row=@($v.Rows)[0]
        Assert-Equal 'Unproven' $row.Result ($entry|ConvertTo-Json -Compress);Assert-Equal 'Inconnu' $row.Etat;Assert-False ($row.Resultat -match '^Appliqu')
        Assert-False $v.AppliedProven;Assert-False (@($v.Facts)[1].Valeur -match '^\d+ GPO appliqu');Assert-Equal 'Inconnu' @($v.Facts)[1].Etat
    }
    $favourable=[pscustomobject]@{Guid=$g;AccessDenied=$false;FilterAllowed=$true;Enabled=$true}
    $zero=Resolve-DomeniaGpoView $c ([pscustomobject]@{ReadStatus='OK';Gpos=@($favourable);Links=@([pscustomobject]@{Gpo=$dn;Som='OU=Postes';AppliedOrder=0})})
    Assert-Equal 'NotApplied' @($zero.Rows)[0].Result 'Drapeaux favorables et ordre nul : non appliquee';Assert-True $zero.AppliedProven;Assert-True (@($zero.Facts)[1].Valeur -match '^0 GPO')
    $noLink=Resolve-DomeniaGpoView $c ([pscustomobject]@{ReadStatus='OK';Gpos=@($favourable);Links=@([pscustomobject]@{Gpo='LocalGPO';Som='Local';AppliedOrder=0})})
    Assert-Equal 'Unproven' @($noLink.Rows)[0].Result;Assert-True (@($noLink.Rows)[0].Resultat -match 'sans lien')
    foreach($order in @($null,'abc',-1)){
        $bad=Resolve-DomeniaGpoView $c ([pscustomobject]@{ReadStatus='OK';Gpos=@($favourable);Links=@([pscustomobject]@{Guid=$g;AppliedOrder=$order})})
        Assert-Equal 'Unproven' @($bad.Rows)[0].Result ('Ordre illisible : '+[string]$order)
    }
    $proven=Resolve-DomeniaGpoView $c ([pscustomobject]@{ReadStatus='OK';Gpos=@([pscustomobject]@{Guid=$g});Links=@([pscustomobject]@{Gpo=$dn;AppliedOrder=2})})
    Assert-Equal 'Applied' @($proven.Rows)[0].Result 'L ordre d application est la preuve'
    $filtered=Resolve-DomeniaGpoView $c ([pscustomobject]@{ReadStatus='OK';Gpos=@([pscustomobject]@{Guid=$g;FilterAllowed='False'})})
    Assert-Equal 'Filtered' @($filtered.Rows)[0].Result 'Un drapeau defavorable explicite suffit a dire non appliquee'
    Assert-Equal 'Disabled' @((Resolve-DomeniaGpoView $c ([pscustomobject]@{ReadStatus='OK';Gpos=@([pscustomobject]@{Guid=$g;Enabled=$false})})).Rows)[0].Result
}
Test-Case 'D075' 'Lien sans GPO identifiable : non prouve, jamais absente du RSoP' {
    $weird=@([pscustomobject]@{Dn='OU=Postes,DC=example,DC=test';GpLink='[LDAP://cn=Weird,cn=policies;0]';GpOptions=0;ReadStatus='OK'})
    $v=Resolve-DomeniaGpoView $weird ([pscustomobject]@{ReadStatus='OK';Gpos=@([pscustomobject]@{Guid=$script:WsGpoA;AccessDenied=$false;FilterAllowed=$true;Enabled=$true});Links=@([pscustomobject]@{Guid=$script:WsGpoA;AppliedOrder=1})})
    $first=@($v.Rows)[0]
    Assert-Equal '' $first.Guid;Assert-Equal 'Unproven' $first.Result;Assert-Equal 'Inconnu' $first.Etat
    Assert-True ($first.Resultat -match 'non identifi');Assert-False ($first.Resultat -match 'Absente')
    Assert-True (@($v.Rows)[1].Lien -match 'lien non identifi');Assert-True (@($v.Facts)[0].Limite -match 'sans GPO identifiable')
    Assert-Equal 'Inconnu' @((Resolve-DomeniaGpoView $weird $null).Rows)[0].Etat
}
Test-Case 'D075' 'Blocage d heritage, lien force et lien desactive' {
    $blocked=@($script:WsContainers[0],([pscustomobject]@{Dn='OU=Siege,DC=example,DC=test';GpLink=$script:WsContainers[1].GpLink;GpOptions=1;ReadStatus='OK'}),$script:WsContainers[2])
    $v=Resolve-DomeniaGpoView $blocked $null
    $r=@{};foreach($row in @($v.Rows)){$r[$row.Guid]=$row}
    Assert-Equal 'Oui' $r[$script:WsGpoA].AttenduParLiens;Assert-Equal 'Oui' $r[$script:WsGpoB].AttenduParLiens 'Le lien du conteneur qui bloque s applique'
    Assert-Equal 'Oui' $r[$script:WsGpoC].AttenduParLiens 'Un lien force traverse le blocage';Assert-Equal 'Non' $r[$script:WsGpoD].AttenduParLiens
    Assert-Equal 'Non' $r[$script:WsGpoF].AttenduParLiens 'Lien bloque par l heritage';Assert-True ($r[$script:WsGpoF].Heritage -match 'Bloqu')
    Assert-Equal 'Oui' @((Resolve-DomeniaGpoView $script:WsContainers $null).Rows|Where-Object{$_.Guid -eq $script:WsGpoF})[0].AttenduParLiens
    $links=@(ConvertFrom-DomeniaGpLink $script:WsContainers[2].GpLink 'DC=example,DC=test')
    Assert-Equal 3 $links.Count;Assert-True $links[0].Enforced;Assert-False $links[1].LinkEnabled;Assert-Equal $script:WsGpoC $links[0].Guid
}
Test-Case 'D075' 'Conteneur non lu : liste incomplete et attente indeterminee' {
    $partial=@($script:WsContainers[0],([pscustomobject]@{Dn='OU=Siege,DC=example,DC=test';ReadStatus='AccessDenied'}),$script:WsContainers[2])
    $v=Resolve-DomeniaGpoView $partial $null
    Assert-False $v.LinksComplete;Assert-Equal 'Estime' @($v.Facts)[0].Etat;Assert-True (@($v.Facts)[0].Limite -match 'incompl')
    $r=@{};foreach($row in @($v.Rows)){$r[$row.Guid]=$row}
    Assert-False $r.ContainsKey($script:WsGpoB);Assert-True ($r[$script:WsGpoF].AttenduParLiens -match '^Ind');Assert-Equal 'Oui' $r[$script:WsGpoC].AttenduParLiens
}

# ---------------------------------------------------------------- D076
Test-Case 'D076' 'Analyse d un texte dsregcmd colle, sans reparation' {
    $s=ConvertFrom-DomeniaDsregStatus $script:WsDsreg
    Assert-True $s.Valid;Assert-Equal 'YES' $s.Values['AzureAdJoined'];Assert-Equal 'EXAMPLE\jdupont, jdupont@example.test' $s.Values['Executing Account Name']
    Assert-True $s.Sections.Contains('SSO State');Assert-Equal 'YES' $s.Sections['SSO State']['AzureAdPrt']
    Assert-Equal '2026-03-10 08:00:00.000 UTC' $s.Values['AzureAdPrtUpdateTime']
    $j=Get-DomeniaJoinStateFacts $s -CollectedAs EndUserSession -EndUser 'EXAMPLE\jdupont' -ExpectedComputer 'pc-01'
    Assert-Equal 'Hybride (AD et Entra ID)' $j.Mode;Assert-Equal 'PrtPresent' $j.SsoVerdict;Assert-True $j.ComputerMatches;Assert-False $j.RepairOffered
    Assert-Equal 1 @($j.Facts|Where-Object{($_.Fait -match 'PRT') -and ($_.Etat -eq 'Constate')}).Count
    Assert-False (ConvertFrom-DomeniaDsregStatus 'texte quelconque').Valid
    $unknown=Get-DomeniaJoinStateFacts (ConvertFrom-DomeniaDsregStatus '');Assert-Equal 'Inconnu' $unknown.Mode;Assert-Equal 'NonEvaluable' $unknown.SsoVerdict;Assert-False $unknown.RepairOffered
}
Test-Case 'D076' 'Sous un compte d administration, aucun verdict sur le jeton SSO de l utilisateur final' {
    $s=ConvertFrom-DomeniaDsregStatus $script:WsDsreg
    foreach($case in @(@{As='AdministrativeAccount';User='EXAMPLE\jdupont'},@{As='Unknown';User='EXAMPLE\jdupont'},@{As='EndUserSession';User=''},@{As='EndUserSession';User='EXAMPLE\mmartin'})){
        $j=Get-DomeniaJoinStateFacts $s -CollectedAs $case.As -EndUser $case.User
        Assert-Equal 'NonEvaluable' $j.SsoVerdict ($case.As+' / '+$case.User)
        Assert-Equal 0 @($j.Facts|Where-Object{($_.Fait -match 'PRT') -and ($_.Etat -eq 'Constate')}).Count
        Assert-True ($j.SsoReason.Length -gt 10)
    }
    Assert-Equal 'Hybride (AD et Entra ID)' (Get-DomeniaJoinStateFacts $s -CollectedAs AdministrativeAccount).Mode 'L etat de jonction du poste reste lisible'
    $admin=ConvertFrom-DomeniaDsregStatus ($script:WsDsreg.Replace('EXAMPLE\jdupont, jdupont@example.test','EXAMPLE\adm-support, adm-support@example.test'))
    Assert-Equal 'NonEvaluable' (Get-DomeniaJoinStateFacts $admin -CollectedAs EndUserSession -EndUser 'jdupont').SsoVerdict 'Declare utilisateur mais produit sous un compte d administration'
    Assert-Equal 'PrtPresent' (Get-DomeniaJoinStateFacts $s -CollectedAs EndUserSession -EndUser 'jdupont@example.test').SsoVerdict
}
Test-Case 'D076' 'Texte provenant d un autre poste signale' {
    $j=Get-DomeniaJoinStateFacts (ConvertFrom-DomeniaDsregStatus $script:WsDsreg) -CollectedAs AdministrativeAccount -ExpectedComputer 'PC-02'
    Assert-False $j.ComputerMatches;Assert-Equal 1 @($j.Facts|Where-Object{$_.Hypothese -match 'autre poste'}).Count
}

# ---------------------------------------------------------------- D077
Test-Case 'D077' 'Date, source et resultat ; donnee ancienne marquee ancienne' {
    $u=ConvertTo-DomeniaUpdateFacts @([pscustomobject]@{Provider='WindowsUpdate';Status='OK';LastUtc=$script:WsNow.AddDays(-3);LastResult='Succeeded';Source='Journal WindowsUpdateClient'},[pscustomobject]@{Provider='WAPT';Status='OK';LastUtc=$script:WsNow.AddDays(-90);LastResult='OK';Source='Agent WAPT local'}) $script:WsNow
    $wu=@($u.Rows)[0];$wapt=@($u.Rows)[1]
    Assert-False $wu.Stale;Assert-Equal 'Succes' $wu.Result;Assert-Equal 'Journal WindowsUpdateClient' $wu.Source;Assert-True ($wu.Date.Length -gt 0);Assert-Equal 'Constate' $wu.State
    Assert-True $wapt.Stale;Assert-Equal 90 $wapt.AgeDays;Assert-True ($wapt.Fact.Valeur -match 'ancienne');Assert-True ($wapt.Fact.Limite -match 'pas connu')
    Assert-Equal 'Agent WAPT' $wapt.Label
    Assert-False @((ConvertTo-DomeniaUpdateFacts @([pscustomobject]@{Provider='WAPT';Status='OK';LastUtc=$script:WsNow.AddDays(-20)}) $script:WsNow -StaleDays 30).Rows)[0].Stale
    Assert-Equal 'Inconnu' @((ConvertTo-DomeniaUpdateFacts @([pscustomobject]@{Provider='WAPT';Status='OK';LastResult='OK'}) $script:WsNow).Rows)[0].State 'Sans date : etat actuel inconnu'
}
Test-Case 'D077' 'Fournisseur absent : indisponible, jamais en panne' {
    $u=ConvertTo-DomeniaUpdateFacts @([pscustomobject]@{Provider='WAPT';Status='Absent'},[pscustomobject]@{Provider='WindowsUpdate';Status='AccessDenied'},[pscustomobject]@{Provider='WindowsUpdate';Status='OK';LastUtc=$script:WsNow.AddDays(-1);LastResult='Failed'}) $script:WsNow
    $absent=@($u.Rows)[0]
    Assert-Equal 'Indisponible' $absent.State;Assert-True ($absent.Result -ne 'Echec');Assert-True ($absent.Fact.Limite -match 'ni une panne')
    Assert-Equal 'Refuse' @($u.Rows)[1].State
    Assert-Equal 1 $u.ReportedFailures 'Seul l echec signale par la source compte';Assert-Equal 'Echec' @($u.Rows)[2].Result
    Assert-Equal 0 (ConvertTo-DomeniaUpdateFacts @([pscustomobject]@{Provider='WAPT';Status='NotInstalled'}) $script:WsNow).ReportedFailures
}

# ---------------------------------------------------------------- D078
Test-Case 'D078' 'Identite coherente : attribution permise' {
    $c=Test-DomeniaMachineIdentityCoherence $script:WsPcA ([pscustomobject]@{Status='OK';Addresses=@('192.0.2.10')}) ([pscustomobject]@{Status='OK';ComputerName='PC-01';Domain='example.test'})
    Assert-Equal 'Coherent' $c.State;Assert-True $c.AttributeObservations;Assert-Equal '192.0.2.10' $c.Address;Assert-Equal 'pc-01' $c.Expected
}
Test-Case 'D078' 'Adresse reattribuee : ni observation ni relation de l ancien poste' {
    $c=Test-DomeniaMachineIdentityCoherence $script:WsPcA ([pscustomobject]@{Status='OK';Addresses=@('192.0.2.10')}) ([pscustomobject]@{Status='OK';ComputerName='PC-02';Domain='example.test'})
    Assert-Equal 'Incoherent' $c.State;Assert-False $c.AttributeObservations;Assert-True ((@($c.Reasons) -join ' ') -match '192\.0\.2\.10')
    $pcB='55555555-5555-4555-8555-555555555555'
    $relations=@([pscustomobject]@{UserLogin='jdupont';ComputerGuid=$script:WsPcA.Guid;Computer='PC-01';Address='192.0.2.10'},[pscustomobject]@{UserLogin='ancien';ComputerGuid='';Computer='';Address='192.0.2.10'},[pscustomobject]@{UserLogin='mmartin';ComputerGuid=$pcB;Computer='PC-02';Address='192.0.2.99'})
    $s=Select-DomeniaRelationsForMachine $relations $pcB '192.0.2.10' 'PC-02'
    Assert-Equal 1 @($s.Kept).Count;Assert-Equal 'mmartin' @($s.Kept)[0].UserLogin
    Assert-Equal 2 @($s.Excluded).Count 'Les relations de l ancien titulaire de l adresse ne sont pas reprises'
    Assert-Equal 0 @(@($s.Kept)|Where-Object{$_.UserLogin -eq 'jdupont'}).Count
}
Test-Case 'D078' 'DNS ou identite non lus, autre domaine ou nom reutilise : pas d attribution' {
    $refused=Test-DomeniaMachineIdentityCoherence $script:WsPcA ([pscustomobject]@{Status='AccessDenied'}) ([pscustomobject]@{Status='OK';ComputerName='PC-01'})
    Assert-Equal 'Unverified' $refused.State;Assert-False $refused.AttributeObservations
    Assert-False (Test-DomeniaMachineIdentityCoherence $script:WsPcA ([pscustomobject]@{Status='OK';Addresses=@('192.0.2.10')}) ([pscustomobject]@{Status='Timeout'})).AttributeObservations
    Assert-Equal 'Incoherent' (Test-DomeniaMachineIdentityCoherence $script:WsPcA ([pscustomobject]@{Status='OK';Addresses=@('192.0.2.10')}) ([pscustomobject]@{Status='OK';ComputerName='PC-01';Domain='autre.test'})).State
    $renamed=Select-DomeniaRelationsForMachine @([pscustomobject]@{UserLogin='x';ComputerGuid='66666666-6666-4666-8666-666666666666';Computer='PC-01'},[pscustomobject]@{UserLogin='y';ComputerGuid='';Computer='PC-01'}) $script:WsPcA.Guid '' 'PC-01'
    Assert-Equal 0 @($renamed.Kept).Count;Assert-Equal 1 @($renamed.Excluded).Count;Assert-Equal 1 @($renamed.ToVerify).Count
}
Test-Case 'D078' 'Nom complet renvoye par le poste : le domaine compte meme sans champ Domain' {
    $dir=[pscustomobject]@{Name='PC-01$';DnsHostName='pc-01.ex.test';Guid='3a760e2f-315a-4155-a1d0-26a319a64cf2'}
    $ok=[pscustomobject]@{Status='OK';Addresses=@('192.0.2.10')}
    $other=Test-DomeniaMachineIdentityCoherence $dir $ok ([pscustomobject]@{Status='OK';DnsHostName='pc-01.autre.test'})
    Assert-Equal 'Incoherent' $other.State 'Homonyme d un autre domaine';Assert-False $other.AttributeObservations;Assert-True ((@($other.Reasons) -join ' ') -match 'autre\.test')
    Assert-Equal 'Coherent' (Test-DomeniaMachineIdentityCoherence $dir $ok ([pscustomobject]@{Status='OK';DnsHostName='PC-01.EX.TEST.'})).State
    Assert-Equal 'Coherent' (Test-DomeniaMachineIdentityCoherence $dir $ok ([pscustomobject]@{Status='OK';ComputerName='PC-01'})).State 'Nom court sans domaine : pas de comparaison de domaine'
}
Test-Case 'D078' 'GUID du poste cible inconnu : aucune relation reprise, aucun motif de GUID different' {
    $relations=@([pscustomobject]@{UserLogin='a';ComputerGuid='55555555-5555-4555-8555-555555555555';Computer='PC-01'},[pscustomobject]@{UserLogin='b';ComputerGuid='66666666-6666-4666-8666-666666666666';Computer='PC-09';Address='192.0.2.10'},[pscustomobject]@{UserLogin='c';ComputerGuid='';Computer='PC-01'})
    $s=Select-DomeniaRelationsForMachine $relations '' '192.0.2.10' 'PC-01'
    Assert-Equal 0 @($s.Kept).Count
    $reasons=(@($s.Excluded)+@($s.ToVerify)|ForEach-Object{$_.Reason}) -join ' | '
    Assert-False ($reasons -match 'GUID diff') $reasons;Assert-True ($reasons -match 'cible inconnu') $reasons
    Assert-Equal 'a,c' (@(@($s.ToVerify)|ForEach-Object{$_.Relation.UserLogin}) -join ',') 'Meme nom, avec ou sans GUID : a verifier'
    Assert-Equal 'b' (@(@($s.Excluded)|ForEach-Object{$_.Relation.UserLogin}) -join ',') 'Meme adresse : jamais reprise'
}

# ---------------------------------------------------------------- D079
Test-Case 'D079' 'Paquet magique : 6 octets FF puis 16 fois l adresse MAC (102 octets)' {
    $p=New-DomeniaWakePacket '00-11-22-AA-BB-CC'
    Assert-True ($p -is [byte[]]) 'Tableau d octets non deroule';Assert-Equal 102 $p.Length
    for($i=0;$i -lt 6;$i++){Assert-Equal 255 ([int]$p[$i])}
    $mac=@(0x00,0x11,0x22,0xAA,0xBB,0xCC)
    for($r=0;$r -lt 16;$r++){for($i=0;$i -lt 6;$i++){Assert-Equal ([int]$mac[$i]) ([int]$p[6+($r*6)+$i]) ('Repetition '+$r)}}
    Assert-Equal ([BitConverter]::ToString($p)) ([BitConverter]::ToString((New-DomeniaWakePacket '0011.22aa.bbcc')))
    Assert-Throws {New-DomeniaWakePacket 'FF-FF-FF-FF-FF-FF'};Assert-Throws {New-DomeniaWakePacket 'pas une mac'}
}
Test-Case 'D079' 'Adresse MAC valide et adresse de diffusion du reseau connu' {
    Assert-True (Test-DomeniaMacAddress '00:11:22:aa:bb:cc').Valid;Assert-Equal '00-11-22-AA-BB-CC' (Test-DomeniaMacAddress '001122aabbcc').Normalized
    foreach($bad in @('','00-00-00-00-00-00','FF-FF-FF-FF-FF-FF','01-00-5E-00-00-01','00-11-22-33-44','00-11:22-33-44-55')){Assert-False (Test-DomeniaMacAddress $bad).Valid ('Accepte : '+$bad)}
    Assert-Equal '192.0.2.255' (Get-DomeniaBroadcastAddress '192.0.2.10' 24)
    Assert-Equal '10.1.7.255' (Get-DomeniaBroadcastAddress '10.1.5.7' -Mask '255.255.252.0')
    foreach($case in @(@('192.0.2.10',32,''),@('192.0.2.10',31,''),@('192.0.2.10',-1,''),@('192.0.2.0',24,''),@('192.0.2.255',24,''),@('192.0.2.10',-1,'255.0.255.0'),@('127.0.0.5',8,''),@('abc',24,''),@('10.1.2.3',7,''),@('10.1.2.3',-1,'254.0.0.0'))){
        Assert-Equal '' (Get-DomeniaBroadcastAddress $case[0] $case[1] $case[2]) ('Diffusion inventee pour '+($case -join ' '))
    }
}
Test-Case 'D079' 'Reveil desactive par defaut et strictement volontaire' {
    $req=[pscustomobject]@{MacAddress='00-11-22-AA-BB-CC';Address='192.0.2.10';PrefixLength=24}
    $nets=@('192.0.2.0/24')
    $off=Test-DomeniaWakeAllowed -Request $req -AllowedNetworks $nets -Trigger 'ExplicitWake'
    Assert-False $off.Allowed 'Desactive par defaut, meme avec geste explicite et perimetre';Assert-True ($off.Reason -match 'sactiv')
    Assert-False (Test-DomeniaWakeAllowed $req $false $nets 'ExplicitWake').Allowed 'Desactive explicitement'
    Assert-False (Test-DomeniaWakeAllowed $req $true $nets 'Selection').Allowed 'Une selection ne reveille pas'
    Assert-False (Test-DomeniaWakeAllowed $req $true $nets 'ExplicitWake' 5).Allowed 'Aucun reveil collectif'
    Assert-False (Test-DomeniaWakeAllowed ([pscustomobject]@{Address='192.0.2.10';PrefixLength=24}) $true $nets 'ExplicitWake').Allowed 'MAC inconnue'
    Assert-False (Test-DomeniaWakeAllowed ([pscustomobject]@{MacAddress='00-11-22-AA-BB-CC';Address='192.0.2.10'}) $true $nets 'ExplicitWake').Allowed 'Reseau inconnu'
    Assert-False (Test-DomeniaWakeAllowed $req $true @('198.51.100.0/24') 'ExplicitWake').Allowed 'Hors perimetre'
    Assert-False (Test-DomeniaWakeAllowed $req $true @() 'ExplicitWake').Allowed 'Perimetre vide'
    $ok=Test-DomeniaWakeAllowed $req $true $nets 'ExplicitWake'
    Assert-True $ok.Allowed;Assert-Equal '192.0.2.255' $ok.Broadcast;Assert-Equal '00-11-22-AA-BB-CC' $ok.MacAddress;Assert-Equal 'WakeOnLanSend' $ok.OperationId
}
Test-Case 'D079' 'Paquet envoye : Demande envoyee, jamais Poste allume' {
    foreach($v in @('NotChecked','Reachable','NoAnswer')){$s=Get-DomeniaWakeState $true '' $v;Assert-True ($s.Text -match '^Demande envoy') $v;Assert-False ($s.Text -match '(?i)allum') ($v+' : '+$s.Text)}
    Assert-Equal 'RequestSent' (Get-DomeniaWakeState $true).State
    $none=Get-DomeniaWakeState $false 'Socket refusee';Assert-Equal 'NotSent' $none.State;Assert-False ($none.Text -match '^Demande envoy')
}

# ---------------------------------------------------------------- D080
Test-Case 'D080' 'Contrat reconnu : seuls les champs de contexte acceptes, sans secret' {
    $c=Test-DomeniaSuiteContract $script:WsContract 'Pesto'
    Assert-True $c.Recognized;Assert-Equal '--computer' $c.Fields['ComputerName'];Assert-Equal '2.1' $c.Version
    $ctx=[pscustomobject]@{ComputerName='PC-01.example.test';UserLogin='jdupont';UserGuid='f4dc5a91-c11b-46b5-893d-9a2cbbad31ad';Password='SECRET_SENTINEL_D080'}
    $plan=Get-DomeniaSuiteLaunchPlan 'Pesto' $script:WsContract $ctx 'ExplicitOpen'
    Assert-True $plan.Allowed;Assert-Equal 'Contract' $plan.Mode;Assert-False $plan.UsesShell
    Assert-Equal '--computer|PC-01.example.test|--user|jdupont' (@($plan.ArgumentList) -join '|')
    Assert-False (($plan|ConvertTo-Json -Depth 4) -match 'SECRET_SENTINEL_D080') 'Aucun champ non declare transmis'
    $cred=New-Object Management.Automation.PSCredential('EX\adm',(New-Object Security.SecureString))
    $withCred=Get-DomeniaSuiteLaunchPlan 'Pesto' $script:WsContract ([pscustomobject]@{ComputerName=$cred;UserLogin='jdupont & calc'}) 'ExplicitOpen'
    Assert-Equal 0 @($withCred.ArgumentList).Count;Assert-Equal 2 @($withCred.Omitted).Count
    Assert-True (@($withCred.Omitted)[0].Reason -match 'Secret')
}
Test-Case 'D080' 'Sans contrat reconnu : ouverture sans argument comme aujourd hui' {
    $bad=@($null,'','{pas du json','[]','"texte"',
        '{"Schema":"DomeniaSuiteContract/2","Tool":"Pesto","Context":{}}',
        '{"Schema":"DomeniaSuiteContract/1","Tool":"FilPro","Context":{}}',
        '{"Schema":"DomeniaSuiteContract/1","Tool":"Pesto","Command":"cmd.exe /c calc"}',
        '{"Schema":"DomeniaSuiteContract/1","Tool":"Pesto","Context":{"Password":"--password"}}',
        '{"Schema":"DomeniaSuiteContract/1","Tool":"Pesto","Context":{"ComputerName":"& calc"}}',
        '{"Schema":"DomeniaSuiteContract/1","Tool":"Pesto","Context":{"ComputerName":"--c","UserLogin":"--C"}}')
    foreach($contract in $bad){
        Assert-False (Test-DomeniaSuiteContract $contract 'Pesto').Recognized ('Reconnu : '+[string]$contract)
        $plan=Get-DomeniaSuiteLaunchPlan 'Pesto' $contract ([pscustomobject]@{ComputerName='PC-01'}) 'ExplicitOpen'
        Assert-True $plan.Allowed;Assert-Equal 'NoArgument' $plan.Mode;Assert-Equal '' $plan.Arguments;Assert-Equal 0 @($plan.ArgumentList).Count
    }
}
Test-Case 'D080' 'Aucune ouverture par navigation, aucune commande shell' {
    foreach($t in @('Navigation','Selection','TabOpened','','explicitopen')){Assert-False (Get-DomeniaSuiteLaunchPlan 'Pesto' $script:WsContract ([pscustomobject]@{ComputerName='PC-01'}) $t).Allowed ('Declencheur accepte : '+$t)}
    $plan=Get-DomeniaSuiteLaunchPlan 'Pesto' $script:WsContract ([pscustomobject]@{ComputerName='PC-01';UserLogin='-rm'}) 'ExplicitOpen'
    Assert-Equal '--computer PC-01' $plan.Arguments 'Une valeur qui ressemble a une option est refusee'
    foreach($arg in @($plan.ArgumentList)){Assert-False ($arg -match '[\s&|;<>^"%]') ('Caractere de shell : '+$arg)}
    Assert-False $plan.UsesShell
}

Test-Case 'UX-37' 'Inventaire du poste : les codes CIM rendent un libelle, une valeur inconnue reste brute' {
    $e=[string][char]0x00E9;$c=[string][char]0x00E7;$p=[string][char]0x02BC
    Assert-Equal 'Poste membre du domaine' (Get-DomeniaInventoryValueText 'Systeme' 'Role dans le domaine' '1') 'Role 1'
    Assert-Equal ('Membre d'+$p+'un groupe de travail') (Get-DomeniaInventoryValueText 'Systeme' 'Role dans le domaine' '4') 'Role 4'
    Assert-Equal 'Portable' (Get-DomeniaInventoryValueText 'Systeme' 'Type de chassis' '10') 'Chassis 10'
    Assert-Equal 'Tour, Portable' (Get-DomeniaInventoryValueText 'Systeme' 'Type de chassis' '6, 10') 'Chassis 6, 10'
    Assert-Equal ('Fran'+$c+'ais') (Get-DomeniaInventoryValueText 'Systeme d exploitation' 'Langue' '1036') 'Langue 1036'
    Assert-Equal ('Fran'+$c+'ais') (Get-DomeniaInventoryValueText 'Systeme d exploitation' 'Langue' '01036') 'Un LANGID decimal avec son zero reste la meme cle'
    Assert-Equal ('Connect'+$e+'e, 1 Gb/s') (Get-DomeniaInventoryValueText 'Cartes reseau' 'Ethernet 1' '2, 1000 Mb/s') 'Carte connectee a 1 Gb/s'
    Assert-Equal ('D'+$e+'connect'+$e+'e, 100 Mb/s') (Get-DomeniaInventoryValueText 'Cartes reseau' 'Ethernet 2' '0, 100 Mb/s') 'Carte deconnectee a 100 Mb/s'
    Assert-Equal ('Connect'+$e+'e') (Get-DomeniaInventoryValueText 'Cartes reseau' 'Ethernet 3' '2') 'Carte sans vitesse rendue'
    Assert-Equal 'XTS-AES 256 bits' (Get-DomeniaInventoryValueText 'BitLocker' 'C: methode' '6') 'BitLocker 6'
    Assert-Equal ('Panne annonc'+$e+'e') (Get-DomeniaInventoryValueText 'Disques physiques' 'DISK0 etat SMART' 'Pred Fail') 'SMART Pred Fail'
    Assert-Equal '4242' (Get-DomeniaInventoryValueText 'Systeme' 'Role dans le domaine' '4242') 'Une valeur hors table ressort brute'
    Assert-Equal 'Gadget' (Get-DomeniaInventoryValueText 'Divers' 'Note' 'Gadget') 'Un element sans table ressort brut'
    Assert-Equal '' (Get-DomeniaInventoryValueText 'Systeme' 'Role dans le domaine' $null) 'Une valeur vide rend vide'
}
