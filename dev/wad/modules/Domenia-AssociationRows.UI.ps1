# Local association enrichment of result rows; extracted without a per-row forwarding wrapper.
function Set-RowAssociationMetadata {
    param($Rows)

    # L'association user-machine est un enrichissement local facultatif.
    # Elle ne doit jamais empecher l'affichage d'un resultat AD.
    $result = New-Object System.Collections.ArrayList
    $enrichmentErrors = 0
    # D043/DS-17: the LinkConfidence column carries the qualification label of the link (Get-DomeniaLinkQualification).
    $qualify = ($null -ne ${function:Get-DomeniaLinkQualification})

    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }

        $association = ""
        $source = ""
        $confidence = ""

        try {
            if ([string]$row.Type -eq "Machine") {
                $computerKey = [string]$row.UPN
                if ([string]::IsNullOrWhiteSpace($computerKey)) { $computerKey = [string]$row.Name }

                # Point 9: the grid column carries the identity note of the fiche, never a silent Unknown.
                $rowGuid = [string](Get-DomeniaMember $row 'Guid' '')
                $links = @(Get-LinksForComputer -Computer $computerKey -Guid $rowGuid)
                if ($links.Count -gt 0) {
                    $association = [string]$links[0].UserLogin + (Get-DomeniaLinkIdentityNote -Link $links[0] -Kind 'Computer' -Guid $rowGuid)
                    $source = [string]$links[0].Source
                    $confidence = if ($qualify) { [string](Get-DomeniaLinkQualification $links[0]).Value } else { [string]$links[0].Confidence }
                }
            }
            elseif ([string]$row.Type -eq "Utilisateur") {
                $userKey = [string]$row.Login
                if ([string]::IsNullOrWhiteSpace($userKey)) { $userKey = [string]$row.Name }

                $rowGuid = [string](Get-DomeniaMember $row 'Guid' '')
                $links = @(Get-LinksForUser -UserLogin $userKey -Guid $rowGuid)
                if ($links.Count -gt 0) {
                    $association = (@($links | ForEach-Object { [string]$_.Computer + (Get-DomeniaLinkIdentityNote -Link $_ -Kind 'User' -Guid $rowGuid) } | Where-Object { $_ } | Sort-Object -Unique) -join ", ")
                    $source = (@($links | ForEach-Object { [string]$_.Source } | Where-Object { $_ } | Sort-Object -Unique) -join ", ")
                    if ($qualify) {
                        $bestLink = Select-DomeniaBestLink $links
                        if ($null -ne $bestLink) { $confidence = [string](Get-DomeniaLinkQualification $bestLink).Value }
                    }
                    else {
                        $bestLink = $links | Sort-Object `
                            @{ Expression = { try { [int]$_.Confidence } catch { 0 } }; Descending = $true }, `
                            @{ Expression = { [string]$_.When }; Descending = $true } | Select-Object -First 1
                        if ($null -ne $bestLink) { $confidence = [string]$bestLink.Confidence }
                    }
                }
            }
        }
        catch {
            $enrichmentErrors++
            if ($enrichmentErrors -le 3) {
                Write-AppLog "Association locale ignoree pour '$([string]$row.Name)' : $($_.Exception.Message)" "WARN"
            }
        }

        try { Set-DomeniaLiveRowValue $row "Association" $association } catch { Write-DomeniaSwallowed 'Core' 'Set-RowAssociationMetadata' $_ }
        try { Set-DomeniaLiveRowValue $row "LinkSource" $source } catch { Write-DomeniaSwallowed 'Core' 'Set-RowAssociationMetadata' $_ }
        try { Set-DomeniaLiveRowValue $row "LinkConfidence" $confidence } catch { Write-DomeniaSwallowed 'Core' 'Set-RowAssociationMetadata' $_ }
        [void]$result.Add($row)
    }

    if ($enrichmentErrors -gt 3) {
        Write-AppLog "$enrichmentErrors enrichissement(s) d'association locale ont ete ignores ; les resultats AD restent affiches." "WARN"
    }

    return @($result)
}
