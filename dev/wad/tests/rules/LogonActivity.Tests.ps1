# Point 27 : activite de connexion AD, approximative et par controleur. Donnees fictives uniquement.
$script:LA0=[datetime]::new(2026,10,14,12,0,0,[DateTimeKind]::Utc)
Test-Case 'P27' 'Activite approximative : lastLogonTimestamp explique, jamais une presence' {
    $s=Get-DomeniaLogonActivitySummary -LastLogonTimestamp ($script:LA0.AddDays(-3).ToFileTimeUtc()) -NowUtc $script:LA0
    Assert-Equal 'Approx' $s.State;Assert-Equal 3 $s.AgeDays;Assert-True ($s.Text -match '9 à 14 jours');Assert-True ($s.Text -match 'présence')
    $e=Get-DomeniaLogonActivitySummary -LastLogonTimestamp 0 -NowUtc $script:LA0
    Assert-Equal 'Empty' $e.State;Assert-True ($e.Text -match 'ne prouve pas')
    $i=Get-DomeniaLogonSyncInterval '7' 'Read';Assert-Equal 7 $i.Days;Assert-Equal 'Read' $i.State
    Assert-True ((Get-DomeniaLogonActivitySummary -LastLogonTimestamp ($script:LA0.AddDays(-1).ToFileTimeUtc()) -Interval $i -NowUtc $script:LA0).Text -match '2 à 7 jours')
    Assert-Equal 'Default' (Get-DomeniaLogonSyncInterval $null 'Absent').State
    Assert-Equal 'NotRead' (Get-DomeniaLogonSyncInterval 'abc' 'Read').State;Assert-Equal 14 (Get-DomeniaLogonSyncInterval 'abc' 'Read').Days
    Assert-Equal 'Refused' (Get-DomeniaLogonSyncInterval $null 'Refused').State
    Assert-True ((Get-DomeniaLogonSyncInterval '0' 'Read').Text -match 'aucun délai')
    Assert-Equal 'au plus 3 jour(s)' (Get-DomeniaLogonLagText 3)
    Assert-True ((Get-DomeniaLogonActivitySummary -LastLogonTimestamp ($script:LA0.AddDays(2).ToFileTimeUtc()) -NowUtc $script:LA0).Text -match 'horloge')
}
Test-Case 'P27' 'lastLogon par controleur : valeur la plus recente et couverture dite' {
    $t=$script:LA0
    $readings=@(
        [pscustomobject]@{Dc='dc1.example.invalid';Kind='RWDC';State='Read';LastLogonUtc=$t.AddHours(-30).ToString('o');Error=''}
        [pscustomobject]@{Dc='dc2.example.invalid';Kind='RWDC';State='Read';LastLogonUtc=$t.AddHours(-2).ToString('o');Error=''}
        [pscustomobject]@{Dc='dc3.example.invalid';Kind='RODC';State='Read';LastLogonUtc='';Error=''}
        [pscustomobject]@{Dc='dc4.example.invalid';Kind='RWDC';State='Unavailable';LastLogonUtc='';Error='Serveur injoignable'}
    )
    $m=Merge-DomeniaLogonReadings -Readings $readings -KnownCount 4 -LastLogonTimestamp ($t.AddDays(-9).ToFileTimeUtc())
    Assert-Equal 'dc2.example.invalid' $m.MostRecentDc;Assert-Equal 3 $m.ReadCount;Assert-False $m.Complete
    Assert-True ($m.Text -match '3 contrôleur\(s\) lu\(s\) sur 4');Assert-True ($m.Text -match 'dc4\.example\.invalid');Assert-True ($m.Text -match 'retard')
    Assert-Equal 'dc2.example.invalid' @($m.Rows)[0].Controleur 'Le plus recent en tete.'
    Assert-True (@($m.Rows|Where-Object{$_.Controleur -eq 'dc3.example.invalid'})[0].Valeur -match 'Aucune connexion')
    $all=Merge-DomeniaLogonReadings -Readings @($readings[0],$readings[1]) -KnownCount 2
    Assert-True $all.Complete;Assert-True ($all.Text -match 'Tous les contrôleurs')
    Assert-False (Merge-DomeniaLogonReadings -Readings @($readings[0],$readings[1]) -KnownCount 2 -ListTruncated $true).Complete 'Une liste tronquee ne couvre pas le domaine.'
    Assert-False (Merge-DomeniaLogonReadings -Readings @($readings[0],$readings[1]) -KnownCount 3).Complete 'Un controleur recense non lu.'
    $none=Merge-DomeniaLogonReadings -Readings @($readings[3]) -KnownCount 1
    Assert-True ($null -eq $none.MostRecentUtc);Assert-True ($none.Text -match 'Aucun contrôleur')
    $text=Format-DomeniaLogonReadingsText -Merge $m -Interval (Get-DomeniaLogonSyncInterval $null 'Absent')
    Assert-True ($text -match 'lecture seule');Assert-True ($text -match '14 jours par défaut');Assert-True ($text -match 'nʼest pas répliqué')
}
