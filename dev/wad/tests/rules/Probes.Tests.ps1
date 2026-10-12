# Requetes WMI pretes a l emploi des widgets (lot L06, TE-06 et FI-17) : catalogue autorise, charge utile du worker,
# chaque transformation (valeur vide, erreur, Map inconnue) et regroupement en tranches avec unites. Regles pures.
. (Join-Path $modules 'Domenia-Boards.Model.ps1')
. (Join-Path $modules 'Domenia-Probes.Model.ps1')
# The catalog cache starts empty (StrictMode of this runner: the variable must exist).
$script:DomeniaProbeCatalog = $null
function New-PrbResult {
    # One workstation result as the LiveConsole worker stores it: rows of property values, a count and an error text.
    param([object[]]$Rows = @(),[int]$Count = 0,[string]$Failure = '',[string]$Skipped = '')
    $result = [pscustomobject]@{ Rows = @($Rows); Count = $Count; Error = $Failure; CheckedUtc = '2026-10-08T10:00:00.0000000Z' }
    if ($Skipped) { Add-Member -InputObject $result -MemberType NoteProperty -Name 'Skipped' -Value $Skipped }
    return $result
}
function New-PrbProbe { param([string]$Transform,[string]$Mode = 'First') return [pscustomobject]@{ Id = 'test.' + $Transform; Category = 'Test'; Name = 'Essai'; Mode = $Mode; Transform = $Transform; Visual = 'Column' } }

Test-Case -Id 'PRB-001' -Name 'Catalogue : identifiants uniques, classes et espaces de noms acceptes par le worker' -Body {
    $catalog = @(Get-DomeniaProbeCatalog)
    Assert-True ($catalog.Count -ge 40) ('catalogue trop court : ' + $catalog.Count)
    Assert-Equal $catalog.Count (@($catalog | ForEach-Object { $_.Id } | Sort-Object -Unique).Count) 'identifiants en double'
    foreach ($probe in $catalog) {
        Assert-True ([string]$probe.Class -match '^[A-Za-z0-9_]+$') ('classe refusee par le worker : ' + $probe.Id)
        Assert-True ([string]$probe.Namespace -match '^[A-Za-z0-9_\\]+$') ('espace de noms refuse par le worker : ' + $probe.Id)
        Assert-True ([string]$probe.Mode -in @('First','Count','All')) ('mode : ' + $probe.Id)
        Assert-True (@($probe.Properties).Count -ge 1) ('aucune propriete : ' + $probe.Id)
        Assert-False ([string]$probe.Class -match '(?i)^(Win32_Product|CIM_Product|Win32_SoftwareFeature)$') ('classe MSI : ' + $probe.Id)
    }
    Assert-True ($null -eq (Get-DomeniaProbe 'sec.uac')) 'requete morte retiree du catalogue'
}
Test-Case -Id 'PRB-002' -Name 'FI-17 : ecrans, cartes physiques, Wi-Fi, chassis, sessions et comptes locaux fiabilises' -Body {
    $screens = Get-DomeniaProbe 'hw.screens'
    Assert-Equal 'WmiMonitorID' ([string]$screens.Class)
    Assert-Equal 'root\wmi' ([string]$screens.Namespace)
    foreach ($id in @('net.adapter','net.speed')) { Assert-True ([string](Get-DomeniaProbe $id).Filter -like '*PhysicalAdapter=TRUE*') ('VPN et Hyper-V inclus : ' + $id) }
    $wifi = Get-DomeniaProbe 'net.wifi'
    Assert-Equal 'MSFT_NetAdapter' ([string]$wifi.Class)
    Assert-True ([string]$wifi.Filter -like '*NdisPhysicalMedium=9*') 'Wi-Fi reconnu par le support 802.11, pas par le nom'
    Assert-False ([string]$wifi.Filter -like '*LIKE*') 'plus de recherche par nom'
    $chassis = Get-DomeniaProbe 'hw.chassis'
    Assert-Equal 'PCSystemTypeEx' (@($chassis.Properties)[0])
    Assert-True ([string]$chassis.Transform -like '*8=Tablette*') 'PCSystemTypeEx 8 = tablette'
    Assert-True ([string](Get-DomeniaProbe 'user.sessions').Filter -like "*AuthenticationPackage<>'Negotiate'*") 'sessions DWM et UMFD exclues'
    Assert-True ([bool](Get-DomeniaProbe 'sec.localusers').SkipOnDc) 'comptes locaux ignores sur un controleur'
    foreach ($id in @('evt.syserrors','evt.unexpected')) { Assert-True ([bool](Get-DomeniaProbe $id).Slow) ('requete lente non signalee : ' + $id) }
    Assert-False ([bool](Get-DomeniaProbe 'hw.ram').Slow)
    Assert-Equal 0 @(Get-DomeniaProbeCatalog | Where-Object { [string]$_.Class -eq 'Win32_DesktopMonitor' }).Count 'Win32_DesktopMonitor sous-compte les ecrans'
}
Test-Case -Id 'PRB-003' -Name 'Charge utile : parties de requete seulement, garde des controleurs transmise' -Body {
    $payload = @(ConvertTo-DomeniaProbePayload -Ids @('sec.localusers','hw.ram','hw.ram','inconnu'))
    Assert-Equal 2 $payload.Count 'identifiant inconnu ou repete ignore'
    Assert-Equal 'DomainController' ([string]$payload[0].Skip)
    Assert-Equal '' ([string]$payload[1].Skip)
    foreach ($item in $payload) { Assert-Equal 'Id,Namespace,Class,Properties,Filter,Mode,Skip' (@($item.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'aucun texte WQL libre' }
}
Test-Case -Id 'PRB-004' -Name 'Transformations : tailles, nombre, vitesse, age, annee, espace libre, version' -Body {
    Assert-Equal 15.9 @(Get-DomeniaProbeValues (New-PrbProbe 'GB') (New-PrbResult -Rows @(,@([string](15.9 * 1GB)))))[0]
    Assert-Equal 3.5 @(Get-DomeniaProbeValues (New-PrbProbe 'GBfromKB') (New-PrbResult -Rows @(,@([string](3.5 * 1MB)))))[0]
    Assert-Equal 512 @(Get-DomeniaProbeValues (New-PrbProbe 'MB') (New-PrbResult -Rows @(,@([string](512 * 1MB)))))[0]
    Assert-Equal 1000 @(Get-DomeniaProbeValues (New-PrbProbe 'Mbps') (New-PrbResult -Rows @(,@('1000000000'))))[0]
    Assert-Equal 4 @(Get-DomeniaProbeValues (New-PrbProbe 'Number') (New-PrbResult -Rows @(,@('4'))))[0]
    $tenDays = [datetime]::UtcNow.AddDays(-10).ToString('o')
    Assert-Equal 10 @(Get-DomeniaProbeValues (New-PrbProbe 'DaysSince') (New-PrbResult -Rows @(,@($tenDays))))[0]
    Assert-Equal '2019' @(Get-DomeniaProbeValues (New-PrbProbe 'Year') (New-PrbResult -Rows @(,@('2019-05-01T00:00:00.0000000Z'))))[0]
    Assert-Equal 25 @(Get-DomeniaProbeValues (New-PrbProbe 'PercentFree') (New-PrbResult -Rows @(,@('25','100'))))[0]
    Assert-Equal 'Windows 11 24H2' @(Get-DomeniaProbeValues (New-PrbProbe 'Release') (New-PrbResult -Rows @(,@('26100','1'))))[0]
    Assert-Equal 'Windows Server 2025' @(Get-DomeniaProbeValues (New-PrbProbe 'Release') (New-PrbResult -Rows @(,@('26100','2'))))[0] 'controleur au meme build que Windows 11'
    Assert-Equal 'Build 12345' @(Get-DomeniaProbeValues (New-PrbProbe 'Release') (New-PrbResult -Rows @(,@('12345','1'))))[0]
    Assert-Equal 'Contoso' @(Get-DomeniaProbeValues (New-PrbProbe 'Text') (New-PrbResult -Rows @(,@('  Contoso  '))))[0]
    Assert-Equal 'A,B' (@(Get-DomeniaProbeValues (New-PrbProbe 'Text' 'All') (New-PrbResult -Rows @(@('A'), @('B')))) -join ',')
    Assert-Equal 3 @(Get-DomeniaProbeValues (New-PrbProbe 'Number' 'Count') (New-PrbResult -Count 3))[0]
}
Test-Case -Id 'PRB-005' -Name 'Transformations : valeur vide, erreur, valeur illisible et controleur ignore ne comptent pas le poste' -Body {
    Assert-Equal 0 @(Get-DomeniaProbeValues (New-PrbProbe 'Text') (New-PrbResult -Rows @(,@('   ')))).Count 'valeur vide'
    Assert-Equal 0 @(Get-DomeniaProbeValues (New-PrbProbe 'Text') (New-PrbResult -Rows @())).Count 'aucune instance'
    Assert-Equal 0 @(Get-DomeniaProbeValues (New-PrbProbe 'GB') (New-PrbResult -Rows @(,@('16')) -Failure 'Acces refuse')).Count 'erreur'
    Assert-Equal 0 @(Get-DomeniaProbeValues (New-PrbProbe 'GB') (New-PrbResult -Rows @(,@('beaucoup')))).Count 'nombre illisible : ignore, jamais une exception'
    Assert-Equal 0 @(Get-DomeniaProbeValues (New-PrbProbe 'DaysSince') (New-PrbResult -Rows @(,@('pas une date')))).Count 'date illisible'
    Assert-Equal 0 @(Get-DomeniaProbeValues (New-PrbProbe 'PercentFree') (New-PrbResult -Rows @(,@('10','0')))).Count 'taille nulle'
    Assert-Equal 0 @(Get-DomeniaProbeValues (New-PrbProbe 'Number' 'Count') (New-PrbResult -Count 12 -Skipped 'DomainController')).Count 'controleur ignore'
    Assert-Equal 0 @(Get-DomeniaProbeValues $null (New-PrbResult -Count 1)).Count 'sans requete'
    Assert-Equal 0 @(Get-DomeniaProbeValues (New-PrbProbe 'Text') $null).Count 'sans resultat'
}
Test-Case -Id 'PRB-006' -Name 'Transformation Map : valeur connue traduite, valeur inconnue gardee telle quelle, vide traduit' -Body {
    $map = New-PrbProbe 'Map:0=Non;1=Oui;2=Oui' 'Count'
    Assert-Equal 'Non' @(Get-DomeniaProbeValues $map (New-PrbResult -Count 0))[0]
    Assert-Equal 'Oui' @(Get-DomeniaProbeValues $map (New-PrbResult -Count 2))[0]
    Assert-Equal '3' @(Get-DomeniaProbeValues $map (New-PrbResult -Count 3))[0] 'valeur hors table : rien d invente'
    $chassis = Get-DomeniaProbe 'hw.chassis'
    Assert-Equal 'Portable' @(Get-DomeniaProbeValues $chassis (New-PrbResult -Rows @(,@('2'))))[0]
    Assert-Equal '9' @(Get-DomeniaProbeValues $chassis (New-PrbResult -Rows @(,@('9'))))[0] 'PCSystemTypeEx 9 = Maximum, jamais une tablette'
    $empty = New-PrbProbe 'Map:=Vide;1=Un'
    Assert-Equal 'Vide' @(Get-DomeniaProbeValues $empty (New-PrbResult -Rows @(,@(''))))[0] 'une Map peut traduire le vide'
}
Test-Case -Id 'PRB-007' -Name 'CO-16 : tranches avec unites et bornes entieres, valeurs peu nombreuses une par une' -Body {
    $ram = New-PrbProbe 'GB'
    $results = @(foreach ($gb in @(3.9, 7.8, 7.9, 15.9, 600)) { New-PrbResult -Rows @(,@([string]($gb * 1GB))) })
    $measured = Measure-DomeniaWidgetData -Probe $ram -Results $results -Visual 'Column'
    Assert-Equal 5 $measured.Machines
    $labels = @($measured.Items | ForEach-Object { [string]$_.Label })
    Assert-Equal ([string][char]0x2264 + ' 4 Go') $labels[0]
    Assert-Equal '> 4 à 8 Go' $labels[1]
    Assert-Equal '> 8 à 16 Go' $labels[2]
    Assert-Equal '> 512 Go' $labels[-1]
    Assert-Equal '1|2|1' ((@($measured.Items | Select-Object -First 3) | ForEach-Object { [string][int]$_.Value }) -join '|')
    $free = Measure-DomeniaWidgetData -Probe (New-PrbProbe 'PercentFree') -Results @((New-PrbResult -Rows @(,@('8','100'))), (New-PrbResult -Rows @(,@('60','100')))) -Visual 'Column'
    Assert-Equal ([string][char]0x2264 + ' 10 %|> 10 à 25 %|> 25 à 50 %|> 50 à 75 %|> 75 %') ((@($free.Items) | ForEach-Object { [string]$_.Label }) -join '|')
    $days = Measure-DomeniaWidgetData -Probe (New-PrbProbe 'DaysSince') -Results @(foreach ($d in @(3, 3, 10)) { New-PrbResult -Rows @(,@([datetime]::UtcNow.AddDays(0 - $d).ToString('o'))) }) -Visual 'Column'
    Assert-Equal '3 j|10 j' ((@($days.Items) | ForEach-Object { [string]$_.Label }) -join '|') 'peu de valeurs : une barre par valeur, avec son unite'
    Assert-Equal '2|1' ((@($days.Items) | ForEach-Object { [string][int]$_.Value }) -join '|')
    $many = Measure-DomeniaWidgetData -Probe (New-PrbProbe 'Number') -Results @(foreach ($n in @(1, 2, 3, 4, 5, 6, 7, 8, 37)) { New-PrbResult -Rows @(,@([string]$n)) }) -Visual 'Column'
    Assert-Equal ([string][char]0x2264 + ' 10|> 10 à 20|> 20 à 30|> 30') ((@($many.Items) | ForEach-Object { [string]$_.Label }) -join '|') 'bornes arrondies'
    $text = Measure-DomeniaWidgetData -Probe (New-PrbProbe 'Text') -Results @((New-PrbResult -Rows @(,@('B'))), (New-PrbResult -Rows @(,@('A'))), (New-PrbResult -Rows @(,@('B'))), (New-PrbResult -Failure 'refus'), (New-PrbResult -Skipped 'DomainController')) -Visual 'Pie'
    Assert-Equal 'B|A' ((@($text.Items) | ForEach-Object { [string]$_.Label }) -join '|')
    Assert-Equal 3 $text.Machines 'poste en erreur non compte'
    Assert-Equal 1 $text.Skipped 'controleur compte a part'
    Assert-True ([string]$text.Summary -like 'Le plus fr*quent : B (2)') ([string]$text.Summary)
}
