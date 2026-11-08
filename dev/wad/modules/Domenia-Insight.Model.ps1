# Insight rules kept for the reviewable ticket report (D104, wired by L18 SP-23): keyed and controllable pseudonyms,
# texts masked twice and bounded, steps classed as attempted, confirmed, refused or not tested.
# L07 (SE-09, 08/10/2026): the other Insight rules (explainable verdicts, next step, timeline, grouped incidents,
# metrics, trace, reproduction fixtures, local assistant, troubleshooting journeys), never called by the application,
# were removed with their tests. New-DomeniaTicketReport keeps its whole call closure.
# Pure decisions: no WPF, no network, no disk, no implicit clock and no random source.
# Providers resolved at call time: Domenia-Common.Model.ps1, Domenia-Access.Model.ps1 (Protect-DomeniaSecretText)
# and Domenia-Support.Model.ps1 (ConvertTo-DomeniaSupportText).

# ---------------------------------------------------------------- shared helpers
function ConvertTo-DomeniaInsightText {
    # The only way a free text enters an Insight output: control characters removed, one line, known names
    # replaced by their pseudonyms (-Map) on the WHOLE text, secrets masked twice, and only then bounded, so that
    # a cut never leaves part of a known name in clear. A value that is not text (credential, secure string,
    # bytes, object, code) is excluded.
    param([AllowNull()]$Value,[ValidateRange(16,8192)][int]$Maximum=240,[object[]]$Map=@())
    if ($null -eq $Value) { return '' }
    $source = $Value
    if ($Value -is [string]) {
        # A name split by a line break or a control character must still be recognised before any cut.
        $source = ([regex]::Replace($Value,'[\x00-\x20\x7F\s]+',' ')).Trim()
        if (@($Map).Count -gt 0) { $source = ConvertTo-DomeniaInsightMaskedNames $source $Map }
    }
    $text = ConvertTo-DomeniaSupportText -Value $source -Limit 8192
    $text = Protect-DomeniaSecretText $text
    return (ConvertTo-DomeniaFlatText $text $Maximum)
}

function Test-DomeniaInsightPseudonymKey {
    param([AllowEmptyString()][AllowNull()][string]$Key)
    return ((-not [string]::IsNullOrWhiteSpace($Key)) -and ($Key.Length -ge 8))
}

function Get-DomeniaInsightKeyedHash {
    # HMAC-SHA256 of a text under the operator key, as upper-case hexadecimal.
    param([Parameter(Mandatory=$true)][string]$Key,[AllowEmptyString()][string]$Text)
    $keyBytes = [Text.Encoding]::UTF8.GetBytes($Key)
    $hmac = New-Object 'System.Security.Cryptography.HMACSHA256' -ArgumentList (,$keyBytes)
    try {
        $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Text))
        return ([BitConverter]::ToString($hash)).Replace('-','')
    } finally { $hmac.Dispose() }
}

function ConvertTo-DomeniaInsightOutcomeText {
    # A Domenia action is shown with what is known of its outcome. Sent is not done.
    param([AllowEmptyString()][AllowNull()][string]$Outcome)
    $value = ([string]$Outcome).Trim()
    if ($value -in @('Confirmed','Confirme','Verified','Verifie')) { return 'Confirme' }
    if ($value -in @('Refused','Refuse','AccessDenied','Denied')) { return 'Refuse' }
    if ($value -in @('Failed','Failure','Echec','Timeout')) { return 'Echec signale' }
    if ($value -in @('Sent','Envoye','Queued')) { return 'Envoye, issue non confirmee' }
    return 'Issue non confirmee'
}

# ---------------------------------------------------------------- D104 reviewable ticket and pseudonyms
function ConvertTo-DomeniaPseudonym {
    # Keyed, stable pseudonym (HMAC-SHA256 under the operator key): the same value and key always give the same
    # suffix, whatever the family label, and another key gives another one. Case is ignored, as in the directory.
    # Without a key, a hash of a name could be reversed from a list of names, so it is refused.
    param([AllowEmptyString()][AllowNull()][string]$Value,[AllowEmptyString()][AllowNull()][string]$Key='',[AllowEmptyString()][AllowNull()][string]$Kind='Valeur',[ValidateRange(6,32)][int]$Length=8)
    if (-not (Test-DomeniaInsightPseudonymKey $Key)) { throw 'Cle de pseudonymisation absente ou trop courte (8 caracteres au moins).' }
    $text = ([string]$Value).Trim()
    if (-not $text) { return '' }
    $label = [regex]::Replace([string]$Kind,'[^A-Za-z]','')
    if (-not $label) { $label = 'Valeur' }
    $hex = Get-DomeniaInsightKeyedHash $Key ('domenia-pseudonym|' + $text.ToLowerInvariant())
    return ($label + '-' + $hex.Substring(0,$Length))
}

function ConvertTo-DomeniaInsightStepStatus {
    # Closed vocabulary of a ticket. Sent, uncertain, failed or a bare "success" without verification stay "attempted".
    param([AllowEmptyString()][AllowNull()][string]$Status)
    $value = ([string]$Status).Trim()
    if ($value -in @('Confirme','Confirmed','Verifie','Verified')) { return 'Confirme' }
    if ($value -in @('Refuse','Refused','Denied','AccessDenied','CredentialsRejected','DecryptionDenied')) { return 'Refuse' }
    if ($value -in @('NonTeste','NotTested','Skipped','NotRun','NotAttempted')) { return 'NonTeste' }
    return 'Tente'
}

function ConvertTo-DomeniaInsightSubjectKind {
    param([AllowEmptyString()][AllowNull()][string]$Type)
    $value = ([string]$Type).Trim()
    if ($value -in @('Utilisateur','User')) { return 'Utilisateur' }
    if ($value -in @('Machine','Computer','Poste')) { return 'Machine' }
    if ($value -in @('Groupe','Group')) { return 'Groupe' }
    return 'Objet'
}

function ConvertTo-DomeniaInsightMaskedNames {
    # Replaces every known identifier by its pseudonym on whole names, longest first, in two passes so that a
    # pseudonym already written is never rewritten by a later, shorter name.
    param([AllowEmptyString()][AllowNull()][string]$Text,[object[]]$Map=@())
    $result = [string]$Text
    if (-not $result) { return '' }
    $entries = @(@($Map) | Where-Object { ($null -ne $_) -and ([string](Get-DomeniaMember $_ 'Original' '')) })
    $entries = @($entries | Sort-Object -Property @{Expression={ ([string](Get-DomeniaMember $_ 'Original' '')).Length };Descending=$true})
    $open = [string][char]1; $close = [string][char]2
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $pattern = '(?<![\p{L}\p{N}_])' + [regex]::Escape([string](Get-DomeniaMember $entries[$i] 'Original' '')) + '(?![\p{L}\p{N}_])'
        $result = [regex]::Replace($result,$pattern,($open + $i + $close),[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $result = $result.Replace(($open + $i + $close),[string](Get-DomeniaMember $entries[$i] 'Pseudonym' ''))
    }
    return $result
}

function New-DomeniaTicketReport {
    # Reviewable ticket summary: attempted, confirmed, refused and not tested, in the sections the operator selects.
    # Only steps tied to the context object by its GUID are kept; texts go through the support sanitizer and the
    # secret masks; a step flagged sensitive keeps its label only. Pseudonyms use the operator key and families;
    # the correspondence table stays beside the local preview, never inside the exported text.
    param(
        [Parameter(Mandatory=$true)]$Context,
        [object[]]$Steps=@(),
        [string[]]$Sections=@('Contexte','Tente','Confirme','Refuse','NonTeste','Limites'),
        [bool]$Pseudonymize=$false,
        [AllowEmptyString()][string]$PseudonymKey='',
        [string[]]$PseudonymKinds=@('Utilisateur','Machine','Groupe','Objet','Compte'),
        [object[]]$Identifiers=@(),
        [Parameter(Mandatory=$true)][datetime]$NowUtc
    )
    $chosen = @(@('Contexte','Tente','Confirme','Refuse','NonTeste','Limites') | Where-Object { $Sections -contains $_ })
    $contextGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Context 'Guid' '')
    $refusal = ''
    if (-not $contextGuid) { $refusal = 'Objet du ticket non identifie par son GUID : aucun compte rendu.' }
    elseif ($Pseudonymize -and (-not (Test-DomeniaInsightPseudonymKey $PseudonymKey))) { $refusal = 'Cle de pseudonymisation requise (8 caracteres au moins) : aucun apercu en clair n est produit a la place.' }
    if ($refusal) {
        return [pscustomobject]@{Format='DomeniaTicket/1';Ready=$false;Reason=$refusal;Text='';Lines=@();Sections=$chosen;Counts=$null;Excluded=$null;Pseudonymized=$false;Map=@();MapInText=$false;RequiresPreview=$true;Destination='Local'}
    }
    $subjectKind = ConvertTo-DomeniaInsightSubjectKind ([string](Get-DomeniaMember $Context 'Type' ''))
    # Known names are collected in full (not cut) so that the masks match the whole texts they replace.
    $rawContextName = Get-DomeniaMember $Context 'Name' ''
    $known = New-Object 'System.Collections.Generic.List[object]'
    $known.Add([pscustomobject]@{Value=(ConvertTo-DomeniaInsightText $rawContextName 1024);Kind=$subjectKind;Family=$subjectKind})
    $known.Add([pscustomobject]@{Value=$contextGuid;Kind=$subjectKind;Family='Identifiant'})
    foreach ($alias in @(Get-DomeniaMember $Context 'Aliases' @())) {
        if ($alias -is [string]) { $known.Add([pscustomobject]@{Value=(ConvertTo-DomeniaInsightText $alias 1024);Kind=$subjectKind;Family=$subjectKind}) }
    }
    foreach ($identifier in @($Identifiers)) {
        if ($null -eq $identifier) { continue }
        $kind = [string](Get-DomeniaMember $identifier 'Kind' 'Objet')
        $known.Add([pscustomobject]@{Value=(ConvertTo-DomeniaInsightText ([string](Get-DomeniaMember $identifier 'Value' '')) 1024);Kind=$kind;Family=$kind})
    }
    # First pass: keep the steps of this object and collect every name they carry; no text is cut yet.
    $kept = New-Object 'System.Collections.Generic.List[object]'
    $counts = [ordered]@{Tente=0;Confirme=0;Refuse=0;NonTeste=0}
    $outOfContext = 0; $unlinked = 0
    foreach ($step in @($Steps)) {
        if ($null -eq $step) { continue }
        $stepGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $step 'TargetGuid' '')
        if (-not $stepGuid) { $unlinked++; continue }
        if ($stepGuid -ne $contextGuid) { $outOfContext++; continue }
        $rawStatus = [string](Get-DomeniaMember $step 'Status' '')
        $status = ConvertTo-DomeniaInsightStepStatus $rawStatus
        $reader = ConvertTo-DomeniaInsightText (Get-DomeniaMember $step 'Reader' '') 1024
        if ($reader) { $known.Add([pscustomobject]@{Value=$reader;Kind='Compte';Family='Compte'}) }
        $targetName = ConvertTo-DomeniaInsightText (Get-DomeniaMember $step 'TargetName' '') 1024
        if ($targetName) { $known.Add([pscustomobject]@{Value=$targetName;Kind=$subjectKind;Family=$subjectKind}) }
        $when = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $step 'WhenUtc' $null)
        $stamp = 'date inconnue'
        if ($null -ne $when) { $stamp = $when.ToString('yyyy-MM-dd HH:mm') + ' UTC' }
        $outcome = ''
        if ($status -eq 'Tente') { $outcome = ConvertTo-DomeniaInsightOutcomeText $rawStatus }
        $kept.Add([pscustomobject]@{Status=$status;When=$stamp;Label=(Get-DomeniaMember $step 'Label' '');Detail=(Get-DomeniaMember $step 'Detail' '');Sensitive=((Get-DomeniaMember $step 'Sensitive' $false) -eq $true);Reader=$reader;Outcome=$outcome})
        $counts[$status] += 1
    }
    $map = New-Object 'System.Collections.Generic.List[object]'
    if ($Pseudonymize) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($item in $known) {
            $value = ([string]$item.Value).Trim()
            if (-not $value) { continue }
            if ($PseudonymKinds -notcontains [string]$item.Kind) { continue }
            if (-not $seen.Add($value)) { continue }
            $map.Add([pscustomobject]@{Kind=[string]$item.Kind;Original=$value;Pseudonym=(ConvertTo-DomeniaPseudonym $value $PseudonymKey ([string]$item.Family))})
        }
    }
    $ordered = @($map | Sort-Object -Property @{Expression={ ([string]$_.Original).Length };Descending=$true})
    # Second pass: every free text is masked on its whole length and only then cut. No later pass rewrites the
    # assembled lines: a pseudonym already written is never masked again.
    $contextName = ConvertTo-DomeniaInsightText $rawContextName 160 $ordered
    $shown = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $kept) {
        $detail = '[detail sensible retire]'
        if (-not $item.Sensitive) { $detail = ConvertTo-DomeniaInsightText $item.Detail 400 $ordered }
        $shown.Add([pscustomobject]@{Status=$item.Status;When=$item.When;Label=(ConvertTo-DomeniaInsightText $item.Label 160 $ordered);Detail=$detail;Reader=(ConvertTo-DomeniaInsightText $item.Reader 120 $ordered);Outcome=$item.Outcome})
    }
    $now = ConvertTo-DomeniaUtcDate $NowUtc
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('DOMENIA | COMPTE RENDU DE TICKET')
    $lines.Add('Genere : ' + $now.ToString('yyyy-MM-dd HH:mm') + ' UTC')
    $lines.Add('Apercu local : relire avant tout export.')
    if ($chosen -contains 'Contexte') {
        $lines.Add(''); $lines.Add('[CONTEXTE]')
        $lines.Add('Objet : ' + $contextName + ' | Type : ' + $subjectKind)
        $lines.Add('Identifiant : ' + (ConvertTo-DomeniaInsightMaskedNames $contextGuid $ordered))
        if ($Pseudonymize) { $lines.Add('Pseudonymisation : active, cle fournie par l operateur.') } else { $lines.Add('Pseudonymisation : inactive.') }
    }
    $titles = @{Tente='TENTE (sans confirmation)';Confirme='CONFIRME';Refuse='REFUSE';NonTeste='NON TESTE'}
    foreach ($status in @('Tente','Confirme','Refuse','NonTeste')) {
        if ($chosen -notcontains $status) { continue }
        $lines.Add(''); $lines.Add('[' + $titles[$status] + '] ' + $counts[$status])
        $items = @($shown | Where-Object { $_.Status -eq $status })
        if ($items.Count -eq 0) { $lines.Add('- aucun element') }
        foreach ($item in $items) {
            $line = '- ' + $item.Label + ' (' + $item.When + ')'
            if ($item.Outcome) { $line += ' [' + $item.Outcome + ']' }
            if ($item.Detail) { $line += ' : ' + $item.Detail }
            if ($item.Reader) { $line += ' [compte : ' + $item.Reader + ']' }
            $lines.Add($line)
        }
    }
    if ($chosen -contains 'Limites') {
        $lines.Add(''); $lines.Add('[LIMITES]')
        $lines.Add('Seuls les elements rattaches a cet objet par son GUID figurent ici.')
        $lines.Add('Secrets masques : aucun mot de passe, aucune cle BitLocker, aucun credential.')
        $lines.Add('Un refus n est pas une absence ; un element non teste reste inconnu.')
        if (($outOfContext + $unlinked) -gt 0) { $lines.Add([string]($outOfContext + $unlinked) + ' element(s) ecarte(s) : autre objet ou rattachement non verifiable.') }
    }
    return [pscustomobject]@{
        Format='DomeniaTicket/1';Ready=$true;Reason='';Text=[string]::Join([Environment]::NewLine,$lines.ToArray());Lines=$lines.ToArray();Sections=$chosen
        Counts=[pscustomobject]$counts;Excluded=[pscustomobject]@{AutreObjet=$outOfContext;NonRattache=$unlinked}
        Pseudonymized=$Pseudonymize;Map=$ordered;MapInText=$false;RequiresPreview=$true;Destination='Local'
    }
}
