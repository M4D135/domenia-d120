# D010, D111-D120 : identite de livraison, PROD autonome, reconstruction, migration ADCC, installation atomique, schema,
# signature, inventaire, stockage, kit de la suite et connecteurs. Donnees fictives, plus des lectures seules de fichiers
# du depot (manifestes, script de build, contrats de workers, coeur, kit visuel) pour verifier les regles sur le reel.
$script:RelDev=Split-Path -Parent $wad
$script:RelBuild='2026.10.02-DOMENIA-1.0-RC1.11.0-D120'
$script:RelOldBuild='2026.10.01-DOMENIA-1.0-RC1.10.7-SELECTION'
$script:RelHotfix='2026.10.09-DOMENIA-1.0-RC1.11.0-HOTFIX'
$script:RelExeSha='3535A6CBCEEA3BAA0066D9024EA316A8DFA2992A463F8EB17CC8BAA40B6BE7AC'
$script:RelNow=[datetime]::SpecifyKind([datetime]'2026-10-02T12:00:00',[DateTimeKind]::Utc)
$script:RelPublisher='CN=Organisation Exemple, O=Exemple, C=FR'
$script:RelThumb=(Get-DomeniaTextHash 'certificat de l editeur').Substring(0,40)
$script:RelOtherThumb=(Get-DomeniaTextHash 'autre certificat meme nom').Substring(0,40)
$script:RelPin=[pscustomobject]@{Name='Organisation Exemple';Thumbprints=@($script:RelThumb)}
$script:RelInstall='C:\Program Files\Domenia'
$script:RelProfile='C:\Users\agent\AppData\Local'
$script:RelEnv=[pscustomobject]@{Commit='5775aba0123456789abcdef0123456789abcdef0';Tools=@([pscustomobject]@{Name='Python';Version='3.12.4'},[pscustomobject]@{Name='Windows PowerShell';Version='5.1.26100.9549'})}
$script:RelReadJson={param([string]$Relative) [IO.File]::ReadAllText((Join-Path $script:RelDev $Relative),[Text.Encoding]::UTF8)|ConvertFrom-Json}
$script:RelContract={
    [pscustomobject]@{
        Schema='DomeniaReleaseContract/1';Product='Domenia';Version='1.0';Stage='RC1.11.0';Date='2026-10-02';Build=$script:RelBuild;Channels=@('DEV','PROD')
        Components=@(
            [pscustomobject]@{Name='Lanceur Domenia';Path='Domenia.exe';VersionPolicy='Distinct';Version='1.0.0.1';Sha256=$script:RelExeSha;Licence='Interne';Provenance='tools/launcher, conserve a l octet'}
            [pscustomobject]@{Name='Moteur Domenia';Path='wad/Domenia-Core.ps1';VersionPolicy='Release'}
            [pscustomobject]@{Name='Bibliotheque AD';Path='wad/Microsoft.ActiveDirectory.Management.dll';VersionPolicy='Distinct';Version='10.0.26100.1';Sha256=(Get-DomeniaTextHash 'addll');Licence='Microsoft';Provenance='RSAT'}
        )
    }
}
$script:RelManifest={
    param([string]$Build,[string]$Tag,[bool]$WithNew)
    $files=@(
        [pscustomobject]@{Path='Domenia.exe';Sha256=$script:RelExeSha;Runtime=$true;PreserveExisting=$false}
        [pscustomobject]@{Path='wad/Domenia-Start.ps1';Sha256=(Get-DomeniaTextHash ('start-'+$Tag));Runtime=$true;PreserveExisting=$false}
        [pscustomobject]@{Path='wad/Domenia-Core.ps1';Sha256=(Get-DomeniaTextHash ('core-'+$Tag));Runtime=$true;PreserveExisting=$false}
        [pscustomobject]@{Path='wad/modules/Domenia-Release.Model.ps1';Sha256=(Get-DomeniaTextHash ('release-'+$Tag));Runtime=$true;PreserveExisting=$false}
        [pscustomobject]@{Path='wad/Domenia.config.json';Sha256=(Get-DomeniaTextHash ('config-'+$Tag));Runtime=$true;PreserveExisting=$true}
    )
    if($WithNew){$files+=[pscustomobject]@{Path='wad/modules/Domenia-Nouveau.UI.ps1';Sha256=(Get-DomeniaTextHash 'nouveau');Runtime=$true;PreserveExisting=$false}}
    [pscustomobject]@{Build=$Build;Files=$files}
}
$script:RelIsWhole={
    param($State,$Manifest)
    # True when every immutable runtime file of the manifest is on disk with exactly the manifest hash.
    foreach($f in @($Manifest.Files)){
        if((-not $f.Runtime) -or $f.PreserveExisting){continue}
        if(-not $State.Hashes.ContainsKey($f.Path)){return $false}
        if([string]$State.Hashes[$f.Path] -cne [string]$f.Sha256){return $false}
    }
    return $true
}
$script:RelSignedFiles={
    @(
        [pscustomobject]@{Path='Domenia.exe';ExpectedSha256=$script:RelExeSha;ActualSha256=$script:RelExeSha;SignatureStatus='Valid';Signer=$script:RelPublisher;SignerThumbprint=$script:RelThumb}
        [pscustomobject]@{Path='wad/Domenia-Core.ps1';ExpectedSha256=(Get-DomeniaTextHash 'core');ActualSha256=(Get-DomeniaTextHash 'core');SignatureStatus='Valid';Signer=$script:RelPublisher;SignerThumbprint=$script:RelThumb}
        [pscustomobject]@{Path='wad/modules/SupportSuite.UI.json';ExpectedSha256=(Get-DomeniaTextHash 'kit');ActualSha256=(Get-DomeniaTextHash 'kit');SignatureStatus='NotSupportedFileFormat';Signer='';SignerThumbprint=''}
    )
}
$script:RelManifestSig=[pscustomobject]@{SignatureStatus='Valid';Signer=$script:RelPublisher;SignerThumbprint=$script:RelThumb}
$script:RelWaptOn={param([string]$Url='https://wapt.example.test') [pscustomobject]@{WAPT=[pscustomobject]@{Enabled=$true;ServerUrl=$Url;WaptGetPath='';LinkCsv='Domenia-user-machine-links.csv'}}}
$script:RelTables={param([int]$Links=0) @{ad_objects=0;park_state=0;user_machine_links=$Links;user_scan_history=0;secret_state=0}}
$script:RelAdccDb={[pscustomobject]@{Name='ADCC.db';SchemaVersion='11';DomeniaSchema='';BaseDn='DC=example,DC=test'}}

# ---------------------------------------------------------------- D010
Test-Case 'D010' 'Une identite unique alimente journal, interface, archive, manifeste et executable' {
    $id=Get-DomeniaReleaseIdentity (& $script:RelContract) 'PROD'
    Assert-True $id.Valid ($id.Errors -join ' ')
    Assert-Equal $script:RelBuild $id.Build;Assert-Equal 'Domenia 1.0 RC1.11.0' $id.DisplayName
    Assert-Equal ('DOMENIA 1.0 '+[char]0x00B7+' RC1.11.0') $id.NavigationText;Assert-Equal 'Domenia 1.0 RC1.11.0 pret.' $id.ReadyText
    Assert-Equal ('DOMENIA 1.0 / '+$script:RelBuild) $id.JournalText 'Ligne de journal portant le build exact'
    Assert-Equal 'Domenia_1.0_RC1.11.0_PROD.zip' $id.ArchiveName;Assert-Equal 'Domenia_1.0_RC1.11.0_DEV.zip' (Get-DomeniaReleaseIdentity (& $script:RelContract) 'DEV').ArchiveName
    Assert-True ($id.ExeLabel -match '^Domenia\.exe 1\.0\.0\.1 \(version de composant distincte, livraison ') 'Version distincte explicite pour l executable'
    Assert-Equal $script:RelBuild @($id.Components|Where-Object{$_.Path -eq 'wad/Domenia-Core.ps1'})[0].Version 'Le moteur porte la version de la livraison'
    Assert-True ($id.DistinctComponents -contains 'Domenia.exe')
    Assert-Equal 'Build exact' $id.Identifies.Journal;Assert-True ($id.Identifies.Interface -match 'Version et etape') 'L interface ne montre que version et etape'
    foreach($surface in @('Source.MasterBuild','Source.DomeniaBuild','Source.Navigation','Source.Pret','Source.BuildScript','Manifeste','Archive')){Assert-Equal 1 @($id.Stamps|Where-Object{$_.Surface -eq $surface}).Count $surface}
    $reloaded=(& $script:RelContract)|ConvertTo-Json -Depth 6|ConvertFrom-Json
    Assert-Equal $id.Fingerprint (Get-DomeniaReleaseIdentity $reloaded 'PROD').Fingerprint 'Meme contrat relu depuis JSON, meme empreinte'
}
Test-Case 'D010' 'Contrat incomplet ou incoherent refuse avec son motif, sans identite partielle' {
    $cases=@(
        @{Why='Build absent';Edit={param($c) $c.Build=''};Match='Champ obligatoire absent : Build'}
        @{Why='Version';Edit={param($c) $c.Version='1.1'};Match='Version incoherente'}
        @{Why='Etape';Edit={param($c) $c.Stage='RC1.10.7'};Match='Etape incoherente'}
        @{Why='Date';Edit={param($c) $c.Date='2026-10-01'};Match='Date incoherente'}
        @{Why='Schema';Edit={param($c) $c.Schema='DomeniaReleaseContract/2'};Match='Schema de contrat non reconnu'}
        @{Why='Canal';Edit={param($c) $c.Channels=@('PROD','RECETTE')};Match='Canal inconnu'}
        @{Why='Exe a la version de livraison';Edit={param($c) $c.Components[0].VersionPolicy='Release'};Match='Domenia.exe est conserve a l octet'}
        @{Why='Exe sans empreinte';Edit={param($c) $c.Components[0].Sha256=''};Match='lie a son empreinte'}
        @{Why='Doublon de casse';Edit={param($c) $c.Components+=[pscustomobject]@{Name='Copie';Path='WAD/domenia-core.ps1';VersionPolicy='Release'}};Match='declare deux fois'}
        @{Why='Version divergente';Edit={param($c) $c.Components[1]|Add-Member -NotePropertyName Version -NotePropertyValue $script:RelOldBuild};Match='Version incoherente pour wad/Domenia-Core.ps1'}
        @{Why='Moteur absent';Edit={param($c) $c.Components=@($c.Components[0],$c.Components[2])};Match='version du moteur non declaree'}
    )
    foreach($case in $cases){
        $c=& $script:RelContract;& $case.Edit $c
        $check=Test-DomeniaReleaseContract $c
        Assert-False $check.Valid $case.Why
        Assert-True (@($check.Errors|Where-Object{$_ -match [regex]::Escape($case.Match)}).Count -ge 1) ($case.Why+' : '+($check.Errors -join ' | '))
        $id=Get-DomeniaReleaseIdentity $c;Assert-False $id.Valid;Assert-Equal '' $id.Build ('Aucune identite partielle : '+$case.Why)
    }
    Assert-True (Test-DomeniaReleaseContract (& $script:RelContract)).Valid
    $devOnly=& $script:RelContract;$devOnly.Channels=@('DEV')
    Assert-False (Get-DomeniaReleaseIdentity $devOnly 'PROD').Valid 'Canal non prevu par le contrat'
    Assert-False (Test-DomeniaReleaseContract $null).Valid
}
Test-Case 'D010' 'Le registre des workers du contrat est celui epingle par le coeur' {
    $raw=& $script:RelReadJson 'tools\operation-contracts.json'
    Assert-Equal (Get-DomeniaWorkerRegistryFingerprint $raw).Sha256 (Get-DomeniaWorkerRegistryFingerprint @($raw|ForEach-Object{$_})).Sha256 'Tableau JSON lu par ConvertFrom-Json 5.1 accepte tel quel'
    $contracts=@($raw|ForEach-Object{$_})
    $fp=Get-DomeniaWorkerRegistryFingerprint $contracts
    Assert-True $fp.Valid ($fp.Errors -join ' ')
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'),[Text.Encoding]::UTF8)
    $pinned=[regex]::Match($coreText,'\$expectedFingerprint\s*=\s*"([A-F0-9]{64})"')
    Assert-True $pinned.Success 'Empreinte epinglee introuvable dans le coeur'
    Assert-Equal $pinned.Groups[1].Value $fp.Sha256 'Meme algorithme que Assert-DomeniaWorkerRegistry'
    $c=& $script:RelContract;$c|Add-Member -NotePropertyName WorkerRegistry -NotePropertyValue ([pscustomobject]@{Operations=$fp.Operations;Sha256=$fp.Sha256})
    Assert-True (Test-DomeniaReleaseContract $c $contracts).Valid
    $changed=@($contracts|ForEach-Object{[pscustomobject]@{Operation=[string]$_.Operation;Sha256=[string]$_.Sha256}});$changed[0].Sha256=(Get-DomeniaTextHash 'autre corps')
    $bad=Test-DomeniaReleaseContract $c $changed;Assert-False $bad.Valid;Assert-True (($bad.Errors -join ' ') -match 'Registre des workers different du contrat')
    Assert-False (Test-DomeniaReleaseContract $c @($changed|Select-Object -Skip 1)).Valid 'Une operation en moins'
    Assert-Equal 1 @((Test-DomeniaReleaseContract (& $script:RelContract)).Warnings).Count 'Registre non declare : avertissement'
    Assert-False (Get-DomeniaWorkerRegistryFingerprint @([pscustomobject]@{Operation='GlobalSearch';Sha256='abc'})).Valid
}
Test-Case 'D010' 'Journal, interface, executable et rapport designent la meme livraison' {
    $id=Get-DomeniaReleaseIdentity (& $script:RelContract)
    $obs=@(
        [pscustomobject]@{Surface='Journal';Value=('2026-10-02 12:00:01 INFO '+$id.JournalText)}
        [pscustomobject]@{Surface='Interface';Value=$id.NavigationText}
        [pscustomobject]@{Surface='Exe';Value='1.0.0.1';Sha256=$script:RelExeSha.ToLowerInvariant()}
        [pscustomobject]@{Surface='Rapport';Value=$script:RelBuild}
    )
    $r=Test-DomeniaReleaseConsistency $id $obs
    Assert-True $r.Consistent $r.Reason;Assert-True $r.Complete
    $exe=@($r.Rows|Where-Object{$_.Surface -eq 'Exe'})[0]
    Assert-Equal 'Version distincte declaree' $exe.State;Assert-True ($exe.Detail -match 'version de composant distincte') 'L executable explicite sa version de composant'
}
Test-Case 'D010' 'Une surface divergente, ressemblante ou absente est signalee' {
    $id=Get-DomeniaReleaseIdentity (& $script:RelContract)
    $good=@([pscustomobject]@{Surface='Journal';Value=$id.JournalText},[pscustomobject]@{Surface='Interface';Value=$id.DisplayName},[pscustomobject]@{Surface='Exe';Value='';Sha256=$script:RelExeSha},[pscustomobject]@{Surface='Rapport';Value=('Build '+$script:RelBuild+'.')})
    Assert-True (Test-DomeniaReleaseConsistency $id $good).Consistent
    $old=Test-DomeniaReleaseConsistency $id @($good[0],[pscustomobject]@{Surface='Interface';Value=('DOMENIA 1.0 '+[char]0x00B7+' RC1.10.7')},$good[2],$good[3])
    Assert-False $old.Consistent;Assert-Equal 'Incoherent' @($old.Rows|Where-Object{$_.Surface -eq 'Interface'})[0].State
    Assert-False (Test-DomeniaReleaseConsistency $id @([pscustomobject]@{Surface='Journal';Value='DOMENIA 1.0 / 2026.10.02-DOMENIA-1.0-RC1.11.01-D120'},$good[1],$good[2],$good[3])).Consistent 'RC1.11.01 n est pas RC1.11.0'
    Assert-False (Test-DomeniaReleaseConsistency $id @($good[0],$good[1],$good[2],[pscustomobject]@{Surface='Rapport';Value=($script:RelBuild+'-BIS')})).Consistent 'Libelle prolonge'
    Assert-False (Test-DomeniaReleaseConsistency $id @($good[0],$good[1],[pscustomobject]@{Surface='Exe';Value='1.0.0.1';Sha256=(Get-DomeniaTextHash 'autre exe')},$good[3])).Consistent 'Un autre executable avec la meme version affichee'
    $noHash=Test-DomeniaReleaseConsistency $id @($good[0],$good[1],[pscustomobject]@{Surface='Exe';Value='1.0.0.1'},$good[3])
    Assert-False $noHash.Consistent;Assert-Equal 'Non verifie' @($noHash.Rows|Where-Object{$_.Surface -eq 'Exe'})[0].State
    $partial=Test-DomeniaReleaseConsistency $id @($good[0],$good[1],$good[2])
    Assert-False $partial.Consistent;Assert-False $partial.Complete;Assert-Equal 'Rapport' (@($partial.MissingSurfaces) -join ',')
    Assert-False (Test-DomeniaReleaseConsistency (Get-DomeniaReleaseIdentity $null) $good).Consistent 'Identite invalide'
}
Test-Case 'D010' 'Une surface qui nomme une autre livraison, ou un journal sans build, ne designe pas la livraison' {
    $id=Get-DomeniaReleaseIdentity (& $script:RelContract)
    $ui=[pscustomobject]@{Surface='Interface';Value=$id.NavigationText}
    $exe=[pscustomobject]@{Surface='Exe';Value='1.0.0.1';Sha256=$script:RelExeSha}
    $rap=[pscustomobject]@{Surface='Rapport';Value=$script:RelBuild}
    $hotfix=Test-DomeniaReleaseConsistency $id @([pscustomobject]@{Surface='Journal';Value=('Build '+$script:RelHotfix+' : '+$id.ReadyText)},$ui,$exe,$rap)
    $row=@($hotfix.Rows|Where-Object{$_.Surface -eq 'Journal'})[0]
    Assert-False $hotfix.Consistent 'Meme version et etape, autre build';Assert-Equal 'Incoherent' $row.State;Assert-True ($row.Detail -match 'HOTFIX') $row.Detail
    $both=Test-DomeniaReleaseConsistency $id @([pscustomobject]@{Surface='Journal';Value=($id.JournalText+' ; ancien '+$script:RelHotfix)},$ui,$exe,$rap)
    Assert-False $both.Consistent 'Le bon build ne couvre pas un autre build nomme sur la meme surface'
    $ready=Test-DomeniaReleaseConsistency $id @([pscustomobject]@{Surface='Journal';Value=$id.ReadyText},$ui,$exe,$rap)
    Assert-False $ready.Consistent 'Version et etape seulement';Assert-Equal 'Non identifie' @($ready.Rows|Where-Object{$_.Surface -eq 'Journal'})[0].State
    $title=Test-DomeniaReleaseConsistency $id @([pscustomobject]@{Surface='Journal';Value=$id.JournalText},[pscustomobject]@{Surface='Interface';Value=($id.NavigationText+' ('+$script:RelHotfix+')')},$exe,$rap)
    Assert-False $title.Consistent;Assert-Equal 'Incoherent' @($title.Rows|Where-Object{$_.Surface -eq 'Interface'})[0].State
    # The window shows version and stage only: the contract refuses a stage already delivered under another build.
    $dup=Test-DomeniaReleaseContract (& $script:RelContract) $null @($script:RelOldBuild,$script:RelHotfix)
    Assert-False $dup.Valid;Assert-True (($dup.Errors -join ' ') -match ('deja publiee sous le build '+[regex]::Escape($script:RelHotfix))) ($dup.Errors -join ' | ')
    Assert-True (Test-DomeniaReleaseContract (& $script:RelContract) $null @($script:RelOldBuild,$script:RelBuild)).Valid 'Etape anterieure ou meme build : accepte'
    Assert-False (Get-DomeniaReleaseIdentity (& $script:RelContract) 'PROD' $null @($script:RelHotfix)).Valid 'Aucune identite pour une etape deja utilisee'
}
Test-Case 'D010' 'Les emplacements du coeur, le script de build, les archives et les manifestes designent la meme livraison' {
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'),[Text.Encoding]::UTF8)
    $buildText=[IO.File]::ReadAllText((Join-Path $script:RelDev 'tools\build_packages.py'),[Text.Encoding]::UTF8)
    $found=[ordered]@{
        'Source.MasterBuild'=[regex]::Match($coreText,'(?m)^\$script:MasterBuild = "([^"]+)"')
        'Source.DomeniaBuild'=[regex]::Match($coreText,'(?m)^\$script:DomeniaBuild = "([^"]+)"')
        'Source.Navigation'=[regex]::Match($coreText,'<TextBlock Text="(DOMENIA \d+\.\d+ \u00B7 [^"]+)"')
        'Source.Pret'=[regex]::Match($coreText,'-Text "(Domenia [^"]+ pret\.)"')
        'Source.BuildScript'=[regex]::Match($buildText,"(?m)^BUILD='([^']+)'")
    }
    $archivePrefix=[regex]::Match($buildText,"out/\('([^']+_)'\+edition\.upper\(\)\+'\.zip'\)")
    # D010: the build script may read the single contract instead of carrying a literal; it then designates the build
    # of tools/release-contract.json and names its archives from the contract Version and Release.
    if (-not $found['Source.BuildScript'].Success -and $buildText -match "(?m)^BUILD=CONTRACT\['Build'\]") {
        $contractText=[IO.File]::ReadAllText((Join-Path $script:RelDev 'tools\release-contract.json'),[Text.Encoding]::UTF8)
        $found['Source.BuildScript']=[regex]::Match($contractText,'"Build"\s*:\s*"([^"]+)"')
        if (-not $archivePrefix.Success -and $buildText.Contains("'Domenia_'+VERSION+'_'+RELEASE+'_'+edition.upper()+'.zip'")) {
            $releaseContract=& $script:RelReadJson 'tools\release-contract.json'
            $archivePrefix=[regex]::Match(('Domenia_'+[string]$releaseContract.Version+'_'+[string]$releaseContract.Release+'_'),'^(.+_)$')
        }
    }
    foreach($key in @($found.Keys)){Assert-True $found[$key].Success ('Emplacement introuvable : '+$key)}
    Assert-True $archivePrefix.Success 'Nom des archives introuvable dans build_packages.py'
    $parts=ConvertFrom-DomeniaBuildLabel $found['Source.MasterBuild'].Groups[1].Value
    Assert-True ($null -ne $parts) 'Build du coeur illisible'
    $current=& $script:RelContract;$current.Build=$parts.Build;$current.Version=$parts.Version;$current.Stage=$parts.Stage;$current.Date=$parts.Date
    $obs=@($found.Keys|ForEach-Object{[pscustomobject]@{Surface=[string]$_;Value=$found[[string]$_].Groups[1].Value}})
    $obs+=[pscustomobject]@{Surface='Archive';Value=($archivePrefix.Groups[1].Value+'PROD.zip')}
    $obs+=[pscustomobject]@{Surface='Manifeste';Value=[string](& $script:RelReadJson 'tools\prod-manifest.json').Build}
    $obs+=[pscustomobject]@{Surface='Manifeste';Value=[string](& $script:RelReadJson 'wad\package-manifest.json').Build}
    Assert-Equal 8 $obs.Count 'Cinq emplacements, l archive et les deux manifestes'
    $same=Test-DomeniaReleaseConsistency (Get-DomeniaReleaseIdentity $current) $obs
    $diverging=@($same.Rows|Where-Object{-not $_.Ok})
    Assert-Equal 0 $diverging.Count ('Emplacements divergents : '+(@($diverging|ForEach-Object{$_.Surface+'='+$_.Observed}) -join ' ; '))
    $target=Test-DomeniaReleaseConsistency (Get-DomeniaReleaseIdentity (& $script:RelContract)) $obs
    Assert-Equal ($parts.Build -ceq $script:RelBuild) (@($target.Rows|Where-Object{-not $_.Ok}).Count -eq 0) 'Un depot non estampille RC1.11.0 est detecte comme different'
    $staleArchive=@($obs|Where-Object{$_.Surface -ne 'Archive'})+[pscustomobject]@{Surface='Archive';Value='Domenia_1.0_RC1.10.6_PROD.zip'}
    Assert-Equal 'Incoherent' @((Test-DomeniaReleaseConsistency (Get-DomeniaReleaseIdentity $current) $staleArchive).Rows|Where-Object{$_.Surface -eq 'Archive'})[0].State 'Nom d archive oublie lors d un changement de version'
}

# ---------------------------------------------------------------- D111
Test-Case 'D111' 'PROD livre : Domenia.exe et wad seulement, deblocage dans wad/Support, demarrage complet' {
    $prod=& $script:RelReadJson 'tools\prod-manifest.json'
    $paths=@(@($prod.Files|ForEach-Object{[string]$_.Path})+'wad/package-manifest.json')
    $startText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Start.ps1'),[Text.Encoding]::UTF8)
    $block=[regex]::Match($startText,'foreach\(\$required in @\(([\s\S]*?)\)\)\{')
    Assert-True $block.Success 'Liste de demarrage introuvable dans Domenia-Start.ps1'
    $required=@([regex]::Matches($block.Groups[1].Value,"'([^']+)'")|ForEach-Object{$_.Groups[1].Value})
    Assert-True ($required.Count -ge 10) 'Liste de demarrage lue'
    $layout=Test-DomeniaProdLayout $paths $required $prod
    Assert-True $layout.Valid ($layout.Errors -join ' | ')
    Assert-Equal 'Domenia.exe,wad' ($layout.RootEntries -join ',')
}
Test-Case 'D111' 'Un fichier DEV, un test, un apercu, un jeu d essai, un lanceur ou un deblocage absent rend PROD non autonome' {
    $base=@('Domenia.exe','wad/Domenia-Start.ps1','wad/Domenia-Modules.ps1','wad/Domenia-Core.ps1','wad/package-manifest.json','wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/Debloquer-Paquet.ps1','wad/Support/.lifecycle.lock','wad/modules/Domenia-Common.Model.ps1')
    Assert-True (Test-DomeniaProdLayout $base).Valid
    $extras=@('TESTER-DOMENIA.cmd','LANCER-Domenia.cmd','Lancer-Domenia.vbs','INSTALLER-MISE-A-JOUR.ps1','tools/build_packages.py','wad/tests/Test-DomeniaRules.ps1','wad/data/Domenia.db','wad/maintenance/Preview-DomeniaUi.ps1','wad/APERCU-INTERFACE.cmd','wad/Lancer.cmd','wad/docs/LIRE-MOI.md','WAD/Domenia-Core.ps1','../Domenia.exe','Domenia.exe/x','wad/CON.ps1')
    # Same kinds of files outside a development folder: refused by their name, wherever they sit.
    $extras+=@('wad/Test-DomeniaRules.ps1','wad/Preview-DomeniaUi.ps1','wad/fixtures/users.json','wad/modules/Domenia-Access.Tests.ps1','wad/modules/DemoDirectory.json','wad/modules/Sample-Users.csv','wad/mocks/ad.json','wad/modules/Mock-Directory.ps1')
    foreach($extra in $extras){
        Assert-False (Test-DomeniaProdLayout ($base+$extra)).Valid ('Accepte a tort : '+$extra)
    }
    foreach($removed in @('wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/.lifecycle.lock','wad/Domenia-Core.ps1','Domenia.exe','wad/package-manifest.json')){
        Assert-False (Test-DomeniaProdLayout @($base|Where-Object{$_ -ne $removed})).Valid ('Requis absent accepte : '+$removed)
    }
    $needsDev=Test-DomeniaProdLayout $base @('wad/modules/Domenia-Common.Model.ps1','wad/tests/Test-DomeniaRules.ps1')
    Assert-False $needsDev.Valid;Assert-True (($needsDev.Errors -join ' ') -match 'necessaire au demarrage absent de PROD : wad/tests/Test-DomeniaRules.ps1')
}
Test-Case 'D111' 'Avec le manifeste PROD, seuls ses fichiers runtime sont admis' {
    $base=@('Domenia.exe','wad/Domenia-Start.ps1','wad/Domenia-Modules.ps1','wad/Domenia-Core.ps1','wad/package-manifest.json','wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/Debloquer-Paquet.ps1','wad/Support/.lifecycle.lock','wad/modules/Domenia-Common.Model.ps1')
    $manifest=[pscustomobject]@{Files=@($base|Where-Object{$_ -ne 'wad/package-manifest.json'}|ForEach-Object{[pscustomobject]@{Path=$_;Runtime=$true}})}
    Assert-True (Test-DomeniaProdLayout $base @() $manifest).Valid 'Fichiers declares'
    $clean='wad/modules/Domenia-Extra.UI.ps1'
    Assert-True (Test-DomeniaProdLayout ($base+$clean)).Valid 'Sans manifeste, un nom propre passe la liste de refus'
    $undeclared=Test-DomeniaProdLayout ($base+$clean) @() $manifest
    Assert-False $undeclared.Valid 'Fichier non declare runtime';Assert-True (($undeclared.Errors -join ' ') -match ('non declare runtime par le manifeste PROD : '+[regex]::Escape($clean)))
    $devOnly=[pscustomobject]@{Files=@($manifest.Files)+[pscustomobject]@{Path=$clean;Runtime=$false}}
    Assert-False (Test-DomeniaProdLayout ($base+$clean) @() $devOnly).Valid 'Fichier DEV seulement (Runtime=false)'
    $declaredTest=[pscustomobject]@{Files=@($manifest.Files)+[pscustomobject]@{Path='wad/modules/Domenia-Access.Tests.ps1';Runtime=$true}}
    Assert-False (Test-DomeniaProdLayout ($base+'wad/modules/Domenia-Access.Tests.ps1') @() $declaredTest).Valid 'Un test declare runtime reste refuse'
}

# ---------------------------------------------------------------- D112
Test-Case 'D112' 'Reconstruction depuis le commit documente : composants identifies et identiques' {
    $c=& $script:RelContract
    $files=@([pscustomobject]@{Path='Domenia.exe';Sha256=$script:RelExeSha},[pscustomobject]@{Path='wad/Microsoft.ActiveDirectory.Management.dll';Sha256=(Get-DomeniaTextHash 'addll')},[pscustomobject]@{Path='wad/Domenia-Core.ps1';Sha256=(Get-DomeniaTextHash 'core')})
    $ref=[pscustomobject]@{Build=$script:RelBuild;Files=$files}
    $r=Compare-DomeniaRebuildManifest $ref ([pscustomobject]@{Build=$script:RelBuild;Files=$files}) $script:RelEnv $c
    Assert-True $r.Identified ((@($r.Unpinned)+@($r.EnvironmentErrors)+@($r.Unidentified)) -join ' | ');Assert-True $r.Reproducible;Assert-Equal 3 $r.Components
    $changed=@($files[0],$files[1],[pscustomobject]@{Path='wad/Domenia-Core.ps1';Sha256=(Get-DomeniaTextHash 'core modifie')},[pscustomobject]@{Path='wad/modules/Nouveau.ps1';Sha256=(Get-DomeniaTextHash 'n')})
    $d=Compare-DomeniaRebuildManifest $ref ([pscustomobject]@{Build=$script:RelBuild;Files=$changed}) $script:RelEnv $c
    Assert-True $d.Identified 'Les composants restent identifies';Assert-False $d.Reproducible
    Assert-Equal 'Modifie' @($d.Differences|Where-Object{$_.Path -eq 'wad/Domenia-Core.ps1'})[0].Kind;Assert-Equal 'Ajoute' @($d.Differences|Where-Object{$_.Path -eq 'wad/modules/Nouveau.ps1'})[0].Kind
    $missing=Compare-DomeniaRebuildManifest $ref ([pscustomobject]@{Build=$script:RelBuild;Files=@($files[0],$files[1])}) $script:RelEnv $c
    Assert-Equal 'Absent' @($missing.Differences|Where-Object{$_.Path -eq 'wad/Domenia-Core.ps1'})[0].Kind
    Assert-False (Compare-DomeniaRebuildManifest $ref ([pscustomobject]@{Build='2026.10.03-DOMENIA-1.0-RC1.11.0-D120';Files=$files}) $script:RelEnv $c).Reproducible 'Autre build'
}
Test-Case 'D112' 'Dependance non epinglee, fichier sans empreinte ou environnement non documente : non identifie' {
    $c=& $script:RelContract
    $files=@([pscustomobject]@{Path='Domenia.exe';Sha256=$script:RelExeSha},[pscustomobject]@{Path='wad/Microsoft.ActiveDirectory.Management.dll';Sha256=(Get-DomeniaTextHash 'addll')})
    $ref=[pscustomobject]@{Build=$script:RelBuild;Files=$files}
    Assert-True (Compare-DomeniaRebuildManifest $ref $ref $script:RelEnv $c).Identified
    $psexec=Compare-DomeniaRebuildManifest $ref ([pscustomobject]@{Build=$script:RelBuild;Files=@($files+[pscustomobject]@{Path='wad/PsExec.exe';Sha256=(Get-DomeniaTextHash 'psexec')})}) $script:RelEnv $c
    Assert-False $psexec.Identified;Assert-True ((@($psexec.Unpinned) -join ' ') -match 'wad/PsExec\.exe \(non declare\)')
    Assert-False (Compare-DomeniaRebuildManifest $ref ([pscustomobject]@{Build=$script:RelBuild;Files=@($files[0],[pscustomobject]@{Path='wad/Microsoft.ActiveDirectory.Management.dll';Sha256=(Get-DomeniaTextHash 'autre dll')})}) $script:RelEnv $c).Identified 'Bibliotheque differente de celle epinglee'
    Assert-False (Compare-DomeniaRebuildManifest $ref $ref $script:RelEnv $null).Identified 'Sans contrat, les binaires ne sont pas epingles'
    $noSha=Compare-DomeniaRebuildManifest $ref ([pscustomobject]@{Build=$script:RelBuild;Files=@($files+[pscustomobject]@{Path='wad/x.ps1';Sha256=''})}) $script:RelEnv $c
    Assert-False $noSha.Identified;Assert-Equal 'wad/x.ps1' (@($noSha.Unidentified) -join ',')
    Assert-False (Compare-DomeniaRebuildManifest $ref $ref $null $c).Identified 'Environnement absent'
    Assert-False (Compare-DomeniaRebuildManifest $ref $ref ([pscustomobject]@{Commit='5775aba';Tools=$script:RelEnv.Tools}) $c).Identified 'Commit abrege'
    Assert-False (Compare-DomeniaRebuildManifest $ref $ref ([pscustomobject]@{Commit=$script:RelEnv.Commit;Tools=@([pscustomobject]@{Name='Python';Version=''})}) $c).Identified 'Outil sans version'
    Assert-False (Compare-DomeniaRebuildManifest $ref $ref ([pscustomobject]@{Commit=$script:RelEnv.Commit;Tools=@()}) $c).Identified 'Outils non declares'
}

# ---------------------------------------------------------------- D113
Test-Case 'D113' 'Le modele suit les sources reelles du coeur : base adoptee sur place, tables remplies si vides' {
    $core=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'),[Text.Encoding]::UTF8)
    $import=[regex]::Match($core,'(?s)function Import-DomeniaLegacyStoreIfNeeded \{.*?\n\}\n')
    Assert-True $import.Success 'Import-DomeniaLegacyStoreIfNeeded introuvable'
    $reader=[IO.File]::ReadAllText((Join-Path $wad 'modules/Domenia-Migration.UI.ps1'),[Text.Encoding]::UTF8)
    foreach($name in @('objets.tsv','parc.tsv','recherches.tsv','secrets-etat.tsv','Domenia-user-machine-links.csv','Get-DomeniaMigrationPlan','Test-DomeniaMigrationIdempotent','LegacyImport')) { Assert-True ($reader.Contains($name)) ('Element absent : '+$name) }
    Assert-False ($reader -match 'Invoke-DomeniaDbExec|Save-DomeniaIndex|Save-UserMachineLinks') 'Pas d ecriture directe du lecteur'
    Assert-True ($import.Value -match 'Invoke-DomeniaLegacyImport') 'Le coeur delegue au lecteur et a la file'
    $path=[regex]::Match($core,'(?s)function Get-DomeniaDatabasePath \{.*?\n\}\n')
    Assert-True ($path.Success -and ($path.Value -match "'ADCC\.db'")) 'Adoption de ADCC.db par Get-DomeniaDatabasePath'
    $init=[regex]::Match($core,'(?s)function Initialize-DomeniaDatabase \{.*?\n\}\n')
    # D115: the core delegates the version decision to this rule, then backs up outside the rotation before migrating.
    Assert-True ($init.Success -and ($init.Value -match 'Test-DomeniaSchemaCompatibility') -and ($init.Value -match 'Backup-DomeniaDatabase -Migration') -and ($init.Value -match "domenia_schema','1'")) 'Sauvegarde puis revision domenia_schema sur une base 11'
}
Test-Case 'D113' 'Migration repetee : aucun doublon de lien, aucune ecriture au second passage' {
    $l1=[pscustomobject]@{UserLogin='jdupont';Computer='PC-001';Source='Saisie manuelle';When='2026-09-01 08:00:00'}
    $l2=[pscustomobject]@{UserLogin='EXAMPLE\mmartin';Computer='PC-002.example.test';Source='Console CIM/DCOM';When='2026-09-02 08:00:00'}
    $l3=[pscustomobject]@{UserLogin='JDUPONT';Computer='pc-001';Source='Saisie manuelle';When='2026-08-01 08:00:00'}
    $l4=[pscustomobject]@{UserLogin='pmoreau';Computer='PC-001$';Source='Console CIM/DCOM';When='2026-09-15 08:00:00'}
    $l5=[pscustomobject]@{UserLogin='SYSTEM';Computer='PC-003';Source='Console CIM/DCOM';When='2026-09-20 08:00:00'}
    $legacy=[pscustomobject]@{ConfigFiles=@('ADCC.config.json','ADCC.theme.cfg');Domain='DC=example,DC=test';Stores=@(
        [pscustomobject]@{Kind='Objets';Path='C:\Outils\ADCC\wad\data\Index\objets.tsv';Rows=120}
        [pscustomobject]@{Kind='Parc';Path='C:\Outils\ADCC\wad\data\Index\parc.tsv';Rows=40}
        [pscustomobject]@{Kind='Liens';Path='C:\Users\agent\AppData\Local\DOMENIA\Domenia-user-machine-links.csv';Links=@($l1,$l2,$l3,$l4,$l5)}
    )}
    $current=[pscustomobject]@{ConfigFiles=@();Domain='example.test';Database=(& $script:RelAdccDb);Tables=(& $script:RelTables);Links=@()}
    $r=Test-DomeniaMigrationIdempotent $legacy $current
    Assert-True $r.Idempotent ('Doublons='+(@($r.DuplicateLinks) -join ',')+' ; second='+$r.SecondWrites);Assert-True $r.Applied
    Assert-Equal 0 $r.SecondWrites;Assert-Equal 0 @($r.DuplicateLinks).Count;Assert-Equal 0 $r.LostLinks
    Assert-Equal 1 $r.First.AdoptCount;Assert-Equal 2 $r.First.ImportCount;Assert-Equal 2 $r.First.CopyCount
    Assert-Equal 2 $r.First.AddCount 'Un lien par poste : PC-001 et PC-002';Assert-Equal 1 $r.First.RejectedCount 'Compte integre rejete'
    Assert-Equal 'pmoreau' @($r.First.Steps|Where-Object{($_.Action -eq 'Ajouter') -and ($_.Key -eq 'PC-001')})[0].Item.UserLogin 'Le lien le plus recent du poste est retenu'
    Assert-Equal 2 @($r.State.Links).Count;Assert-Equal 2 $r.State.Tables['user_machine_links'];Assert-Equal 120 $r.State.Tables['ad_objects']
    Assert-Equal '1' $r.State.Database.DomeniaSchema 'Base adoptee'
    Assert-True ($r.Second.SkipCount -ge 3) 'Second passage : sources ignorees car tables remplies'
    Assert-Equal 0 (Test-DomeniaMigrationIdempotent $legacy $r.State).FirstWrites 'Troisieme passage : rien a ecrire'
}
Test-Case 'D113' 'Table Domenia deja alimentee : aucune fusion, aucun doublon, aucune perte' {
    $mine=[pscustomobject]@{UserLogin='mmartin';Computer='PC-002';Source='Console CIM/DCOM';When='2026-09-30 08:00:00'}
    $legacy=[pscustomobject]@{ConfigFiles=@();Domain='example.test';Stores=@([pscustomobject]@{Kind='Liens';Path='Domenia-user-machine-links.csv';Links=@([pscustomobject]@{UserLogin='mmartin';Computer='PC-002';Source='Saisie manuelle';When='2026-01-01'},[pscustomobject]@{UserLogin='jdupont';Computer='PC-001';When='2026-01-02'})})}
    $current=[pscustomobject]@{ConfigFiles=@();Domain='example.test';Database=[pscustomobject]@{Name='Domenia.db';SchemaVersion='11';DomeniaSchema='1';BaseDn='DC=example,DC=test'};Tables=(& $script:RelTables 1);Links=@($mine)}
    $r=Test-DomeniaMigrationIdempotent $legacy $current
    Assert-True $r.Idempotent;Assert-Equal 1 $r.FirstWrites 'Seule la nouvelle association est ajoutee';Assert-Equal 0 $r.LostLinks
    Assert-Equal 2 @($r.State.Links).Count;Assert-Equal 'Console CIM/DCOM' $r.State.Links[0].Source 'Le lien Domenia n est pas remplace'
    Assert-Equal 1 $r.First.KeepCount 'Association existante conservee'
    Assert-Equal 0 @($r.First.Steps|Where-Object{$_.Kind -eq 'Base'}).Count 'Base Domenia : rien a adopter'
}
Test-Case 'D113' 'Une configuration Domenia deja creee n est jamais ecrasee' {
    $legacy=[pscustomobject]@{ConfigFiles=@('ADCC.config.json','ADCC.login-mode.cfg');Domain='example.test';Stores=@()}
    $current=[pscustomobject]@{ConfigFiles=@('domenia.config.json');Domain='example.test';Database=$null;Tables=(& $script:RelTables);Links=@()}
    $plan=Get-DomeniaMigrationPlan $legacy $current
    Assert-Equal 'Conserver' @($plan.Steps|Where-Object{$_.Source -eq 'ADCC.config.json'})[0].Action 'Configuration Domenia existante conservee'
    Assert-Equal 'Copier' @($plan.Steps|Where-Object{$_.Source -eq 'ADCC.login-mode.cfg'})[0].Action
    $r=Test-DomeniaMigrationIdempotent $legacy $current;Assert-True $r.Idempotent;Assert-Equal 0 @($r.OverwrittenConfig).Count
    Assert-Equal 1 @($plan.Trace|Where-Object{($_.Ancien -eq 'ADCC.config.json') -and ($_.Decision -match 'conservee')}).Count
}
Test-Case 'D113' 'Version, revision ou domaine non verifie, ou demarrage : plan refuse et aucune ecriture' {
    $legacyOf={[pscustomobject]@{ConfigFiles=@('ADCC.config.json');Domain='example.test';Stores=@([pscustomobject]@{Kind='Liens';Path='links.csv';Links=@([pscustomobject]@{UserLogin='jdupont';Computer='PC-001';When='2026-09-01'})})}}
    $currentOf={[pscustomobject]@{ConfigFiles=@();Domain='example.test';Database=(& $script:RelAdccDb);Tables=(& $script:RelTables);Links=@()}}
    $okPlan=Get-DomeniaMigrationPlan (& $legacyOf) (& $currentOf)
    Assert-True $okPlan.Allowed ($okPlan.Blockers -join ' ');Assert-Equal 3 $okPlan.WriteCount 'Reference : copie, adoption, lien'
    $cases=[ordered]@{
        'Version de base 10'={param($l,$c) $c.Database.SchemaVersion='10'}
        'Revision Domenia inconnue'={param($l,$c) $c.Database.DomeniaSchema='2'}
        'Base d un autre domaine'={param($l,$c) $c.Database.BaseDn='DC=autre,DC=test'}
        'Base sans domaine'={param($l,$c) $c.Database.BaseDn=''}
        'Fichiers d un autre domaine'={param($l,$c) $l.Domain='autre.test'}
        'Fichiers sans domaine'={param($l,$c) $l.Domain=''}
        'Une OU n est pas un domaine'={param($l,$c) $l.Domain='OU=Postes,DC=example,DC=test'}
        'Domaine courant inconnu'={param($l,$c) $c.Domain=''}
    }
    foreach($name in @($cases.Keys)){
        $l=& $legacyOf;$c=& $currentOf;& $cases[$name] $l $c
        $p=Get-DomeniaMigrationPlan $l $c
        Assert-False $p.Allowed $name;Assert-True (@($p.Blockers).Count -ge 1) $name
        Assert-Equal 0 $p.WriteCount ('Ecriture planifiee malgre le refus : '+$name);Assert-Equal 0 $p.CopyCount $name;Assert-Equal 0 $p.AddCount $name;Assert-Equal 0 $p.AdoptCount $name
        Assert-Equal 0 @($p.Steps|Where-Object{$_.Action -in @('Copier','Adopter','Importer','Ajouter')}).Count $name
        Assert-True ($p.DeferredCount -ge 1) ('Ecritures reportees et visibles : '+$name)
        $i=Test-DomeniaMigrationIdempotent $l $c
        Assert-False $i.Applied $name;Assert-Equal 0 $i.FirstWrites $name;Assert-Equal 0 @($i.State.ConfigFiles).Count ('Configuration copiee malgre le refus : '+$name)
        Assert-Equal 0 @($i.State.Links).Count $name;Assert-Equal ([string]$c.Database.DomeniaSchema) ([string]$i.State.Database.DomeniaSchema) ('Base adoptee malgre le refus : '+$name)
    }
    $boot=Get-DomeniaMigrationPlan (& $legacyOf) (& $currentOf) -Trigger Startup
    Assert-False $boot.Allowed;Assert-Equal 0 $boot.WriteCount 'Rien au demarrage'
    $bootRun=Test-DomeniaMigrationIdempotent (& $legacyOf) (& $currentOf) -Trigger Startup
    Assert-Equal 0 $bootRun.FirstWrites;Assert-Equal 0 @($bootRun.State.ConfigFiles).Count
}
Test-Case 'D113' 'Noms historiques traces sans maquiller l adoption sur place, sources conservees' {
    $link=[pscustomobject]@{UserLogin='jdupont';Computer='PC-001';When='2026-09-01'}
    $legacy=[pscustomobject]@{ConfigFiles=@('ADCC.ui-profile.cfg','ADCC.favoris.json','notes.txt');Domain='DC=Example,DC=Test';Stores=@(
        [pscustomobject]@{Kind='Liens';Path='C:\Users\agent\AppData\Local\DOMENIA\Domenia-user-machine-links.csv';Links=@($link,[pscustomobject]@{UserLogin='';Computer='PC-9'})}
        [pscustomobject]@{Kind='Favoris';Path='favoris.tsv';Rows=3}
        [pscustomobject]@{Kind='Recherches';Path='recherches.tsv';Rows=0}
    )}
    $current=[pscustomobject]@{ConfigFiles=@();Domain='example.test';Database=(& $script:RelAdccDb);Tables=(& $script:RelTables);Links=@()}
    $p=Get-DomeniaMigrationPlan $legacy $current
    Assert-True $p.Allowed ($p.Blockers -join ' ');Assert-Equal 1 $p.AddCount;Assert-Equal 1 $p.RejectedCount
    Assert-True $p.SourceKept;Assert-Equal 0 @($p.Steps|Where-Object{$_.Action -in @('Supprimer','Deplacer','Remplacer')}).Count
    Assert-Equal 'Ignorer' @($p.Steps|Where-Object{$_.Source -eq 'ADCC.favoris.json'})[0].Action 'Fichier ADCC sans equivalent Domenia'
    Assert-Equal 'Ignorer' @($p.Steps|Where-Object{$_.Source -eq 'favoris.tsv'})[0].Action 'Source inconnue'
    Assert-Equal 1 @($p.Trace|Where-Object{($_.Ancien -eq 'ADCC.ui-profile.cfg') -and ($_.Nouveau -eq 'Domenia.ui-profile.cfg')}).Count
    Assert-Equal 1 @($p.Trace|Where-Object{($_.Ancien -eq 'Domenia-user-machine-links.csv') -and ($_.Nouveau -eq 'user_machine_links')}).Count
    $db=@($p.Trace|Where-Object{$_.Ancien -eq 'ADCC.db'})
    Assert-Equal 1 $db.Count;Assert-True ($db[0].Nouveau -match 'sur place') 'Adoption sur place annoncee';Assert-True ($db[0].Decision -match 'modifie apres sauvegarde') 'Modification annoncee'
    Assert-Equal 0 @($p.Trace|Where-Object{$_.Nouveau -eq 'Domenia.db'}).Count 'Aucune copie fictive vers Domenia.db'
    Assert-True $p.ModifiesLegacyDatabase;Assert-True $p.RequiresBackup
    Assert-Equal 'ADCC.db' @($p.Steps|Where-Object{$_.Action -eq 'Adopter'})[0].Target 'Le fichier garde son nom'
    $unknown=Get-DomeniaMigrationPlan $legacy ([pscustomobject]@{ConfigFiles=@();Domain='example.test';Database=$null;Tables=$null;Links=@()})
    Assert-Equal 0 $unknown.AddCount 'Etat des tables non fourni : rien n est repris'
}

# ---------------------------------------------------------------- D114
Test-Case 'D114' 'Plan : preparer a cote, verifier, basculer sous verrou, garder la precedente' {
    $new=& $script:RelManifest $script:RelBuild 'new' $true
    $staged=@{};foreach($f in $new.Files){$staged[$f.Path]=$f.Sha256}
    $plan=Get-DomeniaInstallPlan $new $staged $script:RelOldBuild
    Assert-True $plan.Allowed ($plan.Blockers -join ' | ')
    Assert-Equal 'Preparer,Verifier,Verrouiller,Sauvegarder,Marquer,Basculer,Valider,Liberer' (@($plan.Steps|ForEach-Object{$_.Step}) -join ',')
    Assert-Equal 'Marquer,Basculer,Valider' (@($plan.Steps|Where-Object{$_.WritesActive}|ForEach-Object{$_.Step}) -join ',') 'Rien n est ecrit dans le runtime avant le marqueur'
    Assert-True $plan.KeepsPrevious;Assert-True $plan.Rollback.Available;Assert-Equal $script:RelOldBuild $plan.Rollback.Target
    Assert-Equal 'wad/Domenia.config.json' ($plan.Preserved -join ',')
}
Test-Case 'D114' 'Une preparation incomplete, modifiee ou non verifiee ne bascule pas' {
    $new=& $script:RelManifest $script:RelBuild 'new' $true
    $ok=@{};foreach($f in $new.Files){$ok[$f.Path]=$f.Sha256}
    $m=$ok.Clone();$m['wad/Domenia-Core.ps1']=(Get-DomeniaTextHash 'alteration');Assert-False (Get-DomeniaInstallPlan $new $m $script:RelOldBuild).Allowed 'Fichier modifie'
    $a=$ok.Clone();$a.Remove('wad/modules/Domenia-Release.Model.ps1');Assert-False (Get-DomeniaInstallPlan $new $a $script:RelOldBuild).Allowed 'Fichier absent'
    $e=$ok.Clone();$e['wad/modules/Inconnu.ps1']=(Get-DomeniaTextHash 'intrus');$x=Get-DomeniaInstallPlan $new $e $script:RelOldBuild
    Assert-False $x.Allowed;Assert-Equal 'wad/modules/Inconnu.ps1' ($x.Undeclared -join ',')
    Assert-False (Get-DomeniaInstallPlan $new $null $script:RelOldBuild).Allowed 'Preparation non verifiee'
    Assert-False (Get-DomeniaInstallPlan $new $ok $script:RelOldBuild -LauncherRunning $true).Allowed 'Domenia ouvert'
    Assert-False (Get-DomeniaInstallPlan $new $ok $script:RelOldBuild -PendingInstall $true).Allowed 'Installation precedente inachevee'
    Assert-False (Get-DomeniaInstallPlan $new $ok $script:RelBuild).Allowed 'Version deja active'
    Assert-False (Get-DomeniaInstallPlan $new $ok $script:RelOldBuild -PreviousIntact $false).Rollback.Available
    $data=[pscustomobject]@{Build=$script:RelBuild;Files=@($new.Files+[pscustomobject]@{Path='wad/data/Domenia.db';Sha256=(Get-DomeniaTextHash 'db');Runtime=$false;PreserveExisting=$false})}
    Assert-False (Get-DomeniaInstallPlan $data $ok $script:RelOldBuild).Allowed 'Les donnees ne font pas partie d une installation'
    $c=$ok.Clone();$c['wad/Domenia.config.json']=(Get-DomeniaTextHash 'config locale');Assert-True (Get-DomeniaInstallPlan $new $c $script:RelOldBuild).Allowed 'Une configuration conservee peut differer'
}
Test-Case 'D114' 'Empreintes passees en dictionnaire generique : meme decision qu avec une table de hachage' {
    $new=& $script:RelManifest $script:RelBuild 'new' $true
    $generic=New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach($f in $new.Files){$generic.Add([string]$f.Path,[string]$f.Sha256)}
    Assert-True (Get-DomeniaInstallPlan $new $generic $script:RelOldBuild).Allowed 'Dictionnaire generique complet'
    [void]$generic.Remove('wad/Domenia-Core.ps1')
    $missing=Get-DomeniaInstallPlan $new $generic $script:RelOldBuild
    Assert-False $missing.Allowed 'Fichier absent du dictionnaire';Assert-Equal 'Absent' @($missing.Verification|Where-Object{$_.Path -eq 'wad/Domenia-Core.ps1'})[0].State
    $old=& $script:RelManifest $script:RelOldBuild 'old' $false
    $observed=New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach($f in $old.Files){$observed.Add([string]$f.Path,[string]$f.Sha256)}
    Assert-True (Test-DomeniaLaunchSet $old $observed).Allowed 'Version complete lue dans un dictionnaire generique'
    [void]$observed.Remove('wad/Domenia-Start.ps1');Assert-False (Test-DomeniaLaunchSet $old $observed).Allowed 'Composant absent'
}
Test-Case 'D114' 'Aucun lancement concurrent ne lit un melange, a chaque etape de l installation' {
    $old=& $script:RelManifest $script:RelOldBuild 'old' $false;$new=& $script:RelManifest $script:RelBuild 'new' $true
    $states=@(Get-DomeniaInstallTimeline $old $new)
    Assert-True ($states.Count -ge 10) 'Chaque remplacement est un etat observable'
    $allowedOld=0;$allowedNew=0
    foreach($s in $states){
        $launch=Test-DomeniaLaunchSet $s.Manifest $s.Hashes @($old,$new) $s.LockHeld $s.PendingMarker
        if($launch.Allowed){
            $wholeOld=(($s.ManifestBuild -ceq $old.Build) -and (& $script:RelIsWhole $s $old))
            $wholeNew=(($s.ManifestBuild -ceq $new.Build) -and (& $script:RelIsWhole $s $new))
            Assert-True ($wholeOld -or $wholeNew) ('Melange lance a l etat '+$s.Index+' '+$s.Step+' '+$s.Detail)
            if($wholeOld){$allowedOld++}
            if($wholeNew){$allowedNew++}
        }
    }
    Assert-True ($allowedOld -ge 1) 'Avant le verrou, l ancienne version complete demarre'
    Assert-True ($allowedNew -ge 1) 'Apres validation, la nouvelle version complete demarre'
    $swaps=@($states|Where-Object{$_.Step -eq 'Basculer'})
    Assert-True ($swaps.Count -ge 4) 'Un etat par remplacement, plus le manifeste'
    Assert-Equal 'wad/package-manifest.json' $swaps[$swaps.Count-1].Detail 'Le manifeste est remplace en dernier'
    Assert-Equal 0 @($swaps|Where-Object{-not $_.PendingMarker}).Count 'Le marqueur couvre toute la bascule'
    Assert-Equal 0 @($swaps|Where-Object{$_.Detail -eq 'Domenia.exe'}).Count 'Domenia.exe identique a l octet : non reecrit'
}
Test-Case 'D114' 'Interruption a chaque etape : version complete ou lancement refuse, jamais un melange' {
    $old=& $script:RelManifest $script:RelOldBuild 'old' $false;$new=& $script:RelManifest $script:RelBuild 'new' $true
    foreach($s in @(Get-DomeniaInstallTimeline $old $new)){
        # The installer died: the operating system released the lock, the pending marker stays on disk.
        $launch=Test-DomeniaLaunchSet $s.Manifest $s.Hashes @($old,$new) $false $s.PendingMarker
        if($launch.Allowed){
            $whole=((($s.ManifestBuild -ceq $old.Build) -and (& $script:RelIsWhole $s $old)) -or (($s.ManifestBuild -ceq $new.Build) -and (& $script:RelIsWhole $s $new)))
            Assert-True $whole ('Melange apres arret a l etat '+$s.Index)
        }
        if($s.Step -eq 'Basculer'){Assert-False $launch.Allowed ('Arret pendant la bascule : lancement refuse, etat '+$s.Index)}
        $r=Resolve-DomeniaInstallInterruption $old.Build $new.Build $s.Step
        Assert-Equal $s.PendingMarker $r.MarkerPresent ('Marqueur, etape '+$s.Step)
        Assert-Equal $r.LaunchAllowed $launch.Allowed ('Resolution et lanceur concordent, etape '+$s.Step)
    }
    $mid=Resolve-DomeniaInstallInterruption $old.Build $new.Build 'Basculer'
    Assert-False $mid.LaunchAllowed;Assert-True ($mid.Action -match 'Restaurer');Assert-True $mid.RollbackAvailable;Assert-Equal '' $mid.ActiveBuild
    Assert-Equal $old.Build (Resolve-DomeniaInstallInterruption $old.Build $new.Build 'Verifier').ActiveBuild
    Assert-Equal $new.Build (Resolve-DomeniaInstallInterruption $old.Build $new.Build 'Valider').ActiveBuild
}
Test-Case 'D114' 'Sans marqueur ni verrou, le controle d empreintes refuse seul un melange' {
    $old=& $script:RelManifest $script:RelOldBuild 'old' $false;$new=& $script:RelManifest $script:RelBuild 'new' $true
    $mid=@(@(Get-DomeniaInstallTimeline $old $new)|Where-Object{$_.Step -eq 'Basculer'})[1]
    $r=Test-DomeniaLaunchSet $mid.Manifest $mid.Hashes @($old,$new) $false $false
    Assert-False $r.Allowed;Assert-True $r.Mixed;Assert-True (@($r.Foreign|Where-Object{$_.Build -eq $new.Build}).Count -ge 1) 'Fichier attribue a la nouvelle version'
    $h=$mid.Hashes.Clone();$h['wad/Domenia-Start.ps1']=(Get-DomeniaTextHash 'inconnu')
    Assert-Equal 'inconnue' @((Test-DomeniaLaunchSet $old $h @($old,$new)).Foreign|Where-Object{$_.Path -eq 'wad/Domenia-Start.ps1'})[0].Build
    $whole=@{};foreach($f in $old.Files){$whole[$f.Path]=$f.Sha256}
    Assert-True (Test-DomeniaLaunchSet $old $whole).Allowed 'Version complete'
    Assert-False (Test-DomeniaLaunchSet $old $whole @() $true $false).Allowed 'Verrou seul'
    Assert-False (Test-DomeniaLaunchSet $old $whole @() $false $true).Allowed 'Marqueur seul'
    $cfg=$whole.Clone();$cfg['wad/Domenia.config.json']=(Get-DomeniaTextHash 'reglage local');Assert-True (Test-DomeniaLaunchSet $old $cfg).Allowed 'Configuration conservee hors controle'
    $missing=$whole.Clone();$missing.Remove('wad/Domenia-Core.ps1');$mr=Test-DomeniaLaunchSet $old $missing
    Assert-False $mr.Allowed;Assert-Equal 'wad/Domenia-Core.ps1' ($mr.Missing -join ',')
}

# ---------------------------------------------------------------- D115
Test-Case 'D115' 'Base plus recente : l ancienne version refuse sans retrograder ni toucher aux recus' {
    foreach($case in @(@('12',''),@('12','1'),@('11','2'))){
        $r=Test-DomeniaSchemaCompatibility -DatabaseVersion $case[0] -DatabaseRevision $case[1] -BackupVerified $true
        $label=($case -join '/')
        Assert-Equal 'Refuser plus recente' $r.Decision $label;Assert-False $r.CanOpen $label;Assert-False $r.CanWrite $label
        Assert-Equal 0 @($r.Steps).Count ('Aucune etape : '+$label);Assert-False $r.Downgrade;Assert-False $r.TouchesReceipts;Assert-True $r.Safety.Safe
        Assert-True ($r.Message -match 'ne la retrograde pas') $label;Assert-True ($r.Message -match 'recus restent intacts') $label
    }
}
Test-Case 'D115' 'Base ancienne : migration en avant apres sauvegarde verifiee seulement' {
    $noBackup=Test-DomeniaSchemaCompatibility -DatabaseVersion '11' -DatabaseRevision ''
    Assert-Equal 'Sauvegarde requise' $noBackup.Decision;Assert-False $noBackup.CanWrite;Assert-True $noBackup.RequiresBackup
    Assert-Equal 'Sauvegarde' (@($noBackup.Steps|ForEach-Object{$_.Target}) -join ',') 'Seule la sauvegarde est ecrite'
    $go=Test-DomeniaSchemaCompatibility -DatabaseVersion '11' -DatabaseRevision '' -BackupVerified $true
    Assert-Equal 'Migrer' $go.Decision;Assert-True $go.CanWrite
    Assert-Equal '11/0>11/1' (@($go.Steps|Where-Object{$_.Action -eq 'Migrer'}|ForEach-Object{$_.From+'>'+$_.To}) -join ',')
    $far=Test-DomeniaSchemaCompatibility -DatabaseVersion '9' -DatabaseRevision '' -BackupVerified $true -OldestUpgradable 9
    Assert-Equal '9/0>10/0,10/0>11/0,11/0>11/1' (@($far.Steps|Where-Object{$_.Action -eq 'Migrer'}|ForEach-Object{$_.From+'>'+$_.To}) -join ',')
    Assert-Equal 'Refuser trop ancienne' (Test-DomeniaSchemaCompatibility -DatabaseVersion '10' -BackupVerified $true).Decision 'Comme le coeur : pas de migration depuis 10'
}
Test-Case 'D115' 'Base courante, absente, illisible ou migration interrompue' {
    $cur=Test-DomeniaSchemaCompatibility -DatabaseVersion '11' -DatabaseRevision '1';Assert-Equal 'Ouvrir' $cur.Decision;Assert-Equal 0 @($cur.Steps).Count
    $none=Test-DomeniaSchemaCompatibility -DatabaseExists $false;Assert-Equal 'Creer' $none.Decision;Assert-Equal 'Creer' $none.Steps[0].Action;Assert-True $none.Safety.Safe 'Creer une base absente est sur'
    Assert-Equal 'Refuser' (Test-DomeniaSchemaCompatibility -DatabaseVersion 'onze').Decision
    Assert-Equal 'Refuser' (Test-DomeniaSchemaCompatibility -DatabaseVersion '11' -DatabaseRevision 'x').Decision
    $stop=Test-DomeniaSchemaCompatibility -DatabaseVersion '11' -DatabaseRevision '' -BackupVerified $true -MigrationInterrupted $true
    Assert-Equal 'Reprise requise' $stop.Decision;Assert-False $stop.CanWrite;Assert-Equal 0 @($stop.Steps).Count
}
Test-Case 'D115' 'Le controle des etapes detecte retour arriere, recus vises et base recreee' {
    $ok=@([pscustomobject]@{Action='Sauvegarder';Target='Sauvegarde';From='11/0';To='11/0'},[pscustomobject]@{Action='Migrer';Target='Base';From='11/0';To='11/1'},[pscustomobject]@{Action='Controler';Target='Base';From='11/1';To='11/1'})
    $clean=Test-DomeniaSchemaStepSafety $ok;Assert-True $clean.Safe ($clean.Findings -join ' ');Assert-False $clean.Downgrade
    $mutations=[ordered]@{
        'Revision en arriere'=@{Step=[pscustomobject]@{Action='Migrer';Target='Base';From='11/1';To='11/0'};Flag='SilentDowngrade'}
        'Version en arriere'=@{Step=[pscustomobject]@{Action='Migrer';Target='Base';From='12/0';To='11/1'};Flag='SilentDowngrade'}
        'Restauration non demandee'=@{Step=[pscustomobject]@{Action='Restaurer';Target='Base';From='11/1';To='11/0'};Flag='SilentDowngrade'}
        'Purge des recus'=@{Step=[pscustomobject]@{Action='Purger';Target='Recus';From='';To=''};Flag='TouchesReceipts'}
        'Ecriture dans le dossier des recus'=@{Step=[pscustomobject]@{Action='Copier';Target='C:\Users\agent\AppData\Local\Domenia\Receipts';From='';To=''};Flag='TouchesReceipts'}
        'Base existante recreee'=@{Step=[pscustomobject]@{Action='Creer';Target='Base';From='';To='11/1'};Flag='RecreatesBase'}
        'Base supprimee'=@{Step=[pscustomobject]@{Action='Supprimer';Target='Base';From='';To=''};Flag='RecreatesBase'}
        'Position illisible'=@{Step=[pscustomobject]@{Action='Migrer';Target='Base';From='onze';To='11/1'};Flag='Unreadable'}
    }
    foreach($name in @($mutations.Keys)){
        $r=Test-DomeniaSchemaStepSafety @($ok+$mutations[$name].Step)
        Assert-False $r.Safe ('Etape dangereuse non detectee : '+$name);Assert-True $r.($mutations[$name].Flag) ($name+' : '+$mutations[$name].Flag)
    }
    $restore=Test-DomeniaSchemaStepSafety @([pscustomobject]@{Action='Restaurer';Target='Base';From='11/1';To='11/0'}) $true
    Assert-True $restore.Safe 'Retour explicite admis';Assert-True $restore.Downgrade;Assert-False $restore.SilentDowngrade
    Assert-False (Test-DomeniaSchemaStepSafety @([pscustomobject]@{Action='Purger';Target='Recus';From='';To=''}) $true).Safe 'Meme explicite, les recus ne sont jamais vises'
}
Test-Case 'D115' 'Retour de version : seule une restauration explicite et verifiee revient en arriere, sans toucher aux recus' {
    $old=Test-DomeniaSchemaCompatibility -DatabaseVersion '11' -DatabaseRevision '2' -BackupVerified $true
    Assert-Equal 'Refuser plus recente' $old.Decision 'Un ancien executable ne retrograde pas la base';Assert-Equal 0 @($old.Steps).Count
    $r=Get-DomeniaSchemaRestorePlan -DatabaseVersion '11' -DatabaseRevision '1' -BackupVersion '11' -BackupRevision '' -BackupVerified $true -Explicit $true
    Assert-Equal 'Restaurer' $r.Decision $r.Message;Assert-Equal 'Sauvegarder,Restaurer' (@($r.Steps|ForEach-Object{$_.Action}) -join ',') 'Base actuelle sauvegardee avant remplacement'
    Assert-True $r.Downgrade 'Retour arriere annonce';Assert-False $r.SilentDowngrade;Assert-False $r.TouchesReceipts;Assert-True $r.Safety.Safe
    Assert-Equal 0 @($r.Steps|Where-Object{$_.Target -notin @('Base','Sauvegarde')}).Count 'Aucune autre cible que la base et sa sauvegarde'
    Assert-True ($r.Message -match 'recus') 'Les recus sont nommes comme non modifies'
    foreach($case in @(
        @{Why='Sans geste explicite';Plan=(Get-DomeniaSchemaRestorePlan -DatabaseVersion '11' -DatabaseRevision '1' -BackupVersion '11' -BackupVerified $true)}
        @{Why='Sauvegarde non verifiee';Plan=(Get-DomeniaSchemaRestorePlan -DatabaseVersion '11' -DatabaseRevision '1' -BackupVersion '11' -Explicit $true)}
        @{Why='Sauvegarde plus recente que la version';Plan=(Get-DomeniaSchemaRestorePlan -DatabaseVersion '11' -DatabaseRevision '1' -BackupVersion '12' -BackupVerified $true -Explicit $true)}
        @{Why='Position illisible';Plan=(Get-DomeniaSchemaRestorePlan -DatabaseVersion 'onze' -BackupVersion '11' -BackupVerified $true -Explicit $true)}
    )){
        Assert-Equal 'Refuser' $case.Plan.Decision $case.Why;Assert-Equal 0 @($case.Plan.Steps).Count $case.Why;Assert-False $case.Plan.Downgrade $case.Why
    }
}
Test-Case 'D115' 'Aucune combinaison ne retrograde, ne recree une base existante ni ne touche aux recus' {
    foreach($v in @('9','10','11','12','13')){foreach($rev in @('','1','2')){foreach($backup in @($true,$false)){foreach($stop in @($true,$false)){
        $r=Test-DomeniaSchemaCompatibility -DatabaseVersion $v -DatabaseRevision $rev -BackupVerified $backup -MigrationInterrupted $stop -OldestUpgradable 9
        $label=$v+'/'+$rev+' sauvegarde='+$backup+' interrompue='+$stop
        # The audit is recomputed here from the steps, independently of the flags the function returned.
        $audit=Test-DomeniaSchemaStepSafety @($r.Steps) $false $true
        Assert-True $audit.Safe ($label+' : '+($audit.Findings -join ' '));Assert-False $r.Downgrade $label;Assert-False $r.TouchesReceipts $label
        Assert-Equal 0 @($r.Steps|Where-Object{$_.Action -eq 'Creer'}).Count ('Base existante recreee : '+$label)
        Assert-Equal 0 @($r.Steps|Where-Object{$_.Target -notin @('Base','Sauvegarde')}).Count $label
        $newer=(([int]$v -gt 11) -or (([int]$v -eq 11) -and ($rev -eq '2')))
        if($newer -or $stop){Assert-False $r.CanWrite ('Ecriture interdite : '+$label)}
        if((-not $backup) -and ($r.Decision -ne 'Ouvrir')){Assert-False $r.CanWrite ('Ecriture sans sauvegarde : '+$label)}
    }}}}
}

# ---------------------------------------------------------------- D116
Test-Case 'D116' 'Empreinte d integrite et confiance de l editeur sont deux reponses distinctes' {
    $unsigned=@(& $script:RelSignedFiles|ForEach-Object{$_.SignatureStatus='NotSigned';$_.Signer='';$_.SignerThumbprint='';$_})
    $v=Get-DomeniaSignatureVerdict $unsigned $script:RelPin
    Assert-Equal 'Conforme, editeur non prouve' $v.Overall;Assert-False $v.DistributionSignatureValid
    Assert-Equal 3 @($v.Files|Where-Object{$_.Integrity -eq 'Conforme'}).Count 'Integrite conforme'
    Assert-Equal 'Non signe' @($v.Files|Where-Object{$_.Path -eq 'Domenia.exe'})[0].Publisher
    Assert-True ($v.IntegrityNote -match 'pas l identite')
    $json=@($v.Files|Where-Object{$_.Path -like '*.json'})[0];Assert-False $json.Signable;Assert-False $json.SignatureValid 'Fichier non signable sans manifeste signe'
    Assert-False (Get-DomeniaSignatureVerdict (& $script:RelSignedFiles) ([pscustomobject]@{Name='Autre Editeur';Thumbprints=@($script:RelOtherThumb)}) $script:RelManifestSig).DistributionSignatureValid 'Editeur inattendu'
    Assert-False (Get-DomeniaSignatureVerdict (& $script:RelSignedFiles) $null $script:RelManifestSig).DistributionSignatureValid 'Editeur attendu non configure'
    $noHash=@(& $script:RelSignedFiles|ForEach-Object{$_.ActualSha256='';$_})
    $u=Get-DomeniaSignatureVerdict $noHash $script:RelPin $script:RelManifestSig
    Assert-False $u.DistributionSignatureValid 'Signature valide sans integrite verifiee';Assert-Equal 'Integrite non verifiee' $u.Overall
}
Test-Case 'D116' 'Distribution d origine signee par le certificat epingle : statut de signature valide' {
    $v=Get-DomeniaSignatureVerdict (& $script:RelSignedFiles) $script:RelPin $script:RelManifestSig
    Assert-True $v.DistributionSignatureValid $v.Overall;Assert-Equal 'Signee et conforme' $v.Overall;Assert-True $v.PublisherPinned
    Assert-Equal 'Couvert par le manifeste signe' @($v.Files|Where-Object{$_.Path -like '*.json'})[0].Publisher
    Assert-True (Get-DomeniaSignatureVerdict (& $script:RelSignedFiles) $script:RelThumb $script:RelManifestSig).DistributionSignatureValid 'Empreinte seule'
    $renewed=[pscustomobject]@{Name='Organisation Exemple';Thumbprints=@($script:RelOtherThumb,$script:RelThumb.ToLowerInvariant())}
    Assert-True (Get-DomeniaSignatureVerdict (& $script:RelSignedFiles) $renewed $script:RelManifestSig).DistributionSignatureValid 'Certificat renouvele : plusieurs empreintes, casse indifferente'
}
Test-Case 'D116' 'Un nom d editeur ne prouve rien : seul le certificat epingle compte' {
    foreach($nameOnly in @('Organisation Exemple',$script:RelPublisher,[pscustomobject]@{Name='Organisation Exemple';Thumbprints=@()})){
        $v=Get-DomeniaSignatureVerdict (& $script:RelSignedFiles) $nameOnly $script:RelManifestSig
        Assert-False $v.DistributionSignatureValid ('Nom seul : '+[string]$nameOnly);Assert-False $v.PublisherPinned
        Assert-True (@($v.Files|Where-Object{$_.Publisher -match 'nom seul'}).Count -ge 2) 'Editeur non prouve par un nom'
    }
    $cases=[ordered]@{
        'Meme CN, autre organisation, autre certificat'=@{Signer='CN=Organisation Exemple, O=Autre Societe, C=US';Print=$script:RelOtherThumb}
        'Meme sujet complet, autre certificat'=@{Signer=$script:RelPublisher;Print=$script:RelOtherThumb}
        'Empreinte du signataire non fournie'=@{Signer=$script:RelPublisher;Print=''}
    }
    foreach($name in @($cases.Keys)){
        $files=@(& $script:RelSignedFiles|ForEach-Object{if($_.SignatureStatus -eq 'Valid'){$_.Signer=$cases[$name].Signer;$_.SignerThumbprint=$cases[$name].Print};$_})
        $manifest=[pscustomobject]@{SignatureStatus='Valid';Signer=$cases[$name].Signer;SignerThumbprint=$cases[$name].Print}
        $v=Get-DomeniaSignatureVerdict $files $script:RelPin $manifest
        Assert-False $v.DistributionSignatureValid $name;Assert-True ($v.Overall -ne 'Signee et conforme') $name;Assert-False $v.ManifestSigned $name
        Assert-Equal 0 @($v.Files|Where-Object{$_.Publisher -eq 'Editeur verifie'}).Count $name
    }
    $same=Get-DomeniaSignatureVerdict @(& $script:RelSignedFiles|ForEach-Object{$_.Signer='CN=Organisation Exemple, O=Autre Societe, C=US';$_.SignerThumbprint=$script:RelOtherThumb;$_}) $script:RelPin
    Assert-Equal 'Editeur inattendu : meme nom, autre certificat' @($same.Files|Where-Object{$_.Path -eq 'Domenia.exe'})[0].Publisher
}
Test-Case 'D116' 'Toute modification de la distribution fait perdre le statut de signature valide' {
    $edits=[ordered]@{
        'Script signe modifie'={param($f,$m,$u) $f[1].ActualSha256=(Get-DomeniaTextHash 'core modifie');$f[1].SignatureStatus='HashMismatch'}
        'Script remplace par un autre script signe du meme editeur'={param($f,$m,$u) $f[1].ActualSha256=(Get-DomeniaTextHash 'autre script signe')}
        'Executable remplace par un executable signe ailleurs'={param($f,$m,$u) $f[0].ActualSha256=(Get-DomeniaTextHash 'autre exe');$f[0].Signer='CN=Inconnu';$f[0].SignerThumbprint=$script:RelOtherThumb}
        'JSON modifie et manifeste regenere'={param($f,$m,$u) $f[2].ExpectedSha256=(Get-DomeniaTextHash 'kit modifie');$f[2].ActualSha256=(Get-DomeniaTextHash 'kit modifie');$m.SignatureStatus='HashMismatch'}
        'JSON modifie'={param($f,$m,$u) $f[2].ActualSha256=(Get-DomeniaTextHash 'kit modifie')}
        'Fichier retire'={param($f,$m,$u) $f[1]|Add-Member -NotePropertyName Present -NotePropertyValue $false;$f[1].ActualSha256=''}
        'Fichier ajoute'={param($f,$m,$u) $u.Add('wad/modules/Ajout.ps1')}
        'Manifeste signe par un autre'={param($f,$m,$u) $m.Signer='CN=Autre';$m.SignerThumbprint=$script:RelOtherThumb}
        'Tout re-signe avec un certificat de meme nom'={param($f,$m,$u)
            $f[1].ExpectedSha256=(Get-DomeniaTextHash 'core piege');$f[1].ActualSha256=(Get-DomeniaTextHash 'core piege')
            foreach($x in @($f[0],$f[1])){$x.Signer='CN=Organisation Exemple, O=Autre Societe, C=US';$x.SignerThumbprint=$script:RelOtherThumb}
            $m.Signer='CN=Organisation Exemple, O=Autre Societe, C=US';$m.SignerThumbprint=$script:RelOtherThumb}
    }
    foreach($name in @($edits.Keys)){
        $files=@(& $script:RelSignedFiles);$manifest=[pscustomobject]@{SignatureStatus='Valid';Signer=$script:RelPublisher;SignerThumbprint=$script:RelThumb};$added=New-Object 'System.Collections.Generic.List[string]'
        & $edits[$name] $files $manifest $added
        $v=Get-DomeniaSignatureVerdict $files $script:RelPin $manifest $added.ToArray()
        Assert-False $v.DistributionSignatureValid ('Statut valide conserve : '+$name)
        Assert-True ($v.Overall -ne 'Signee et conforme') $name
    }
    $nothing=Get-DomeniaSignatureVerdict @() $script:RelPin $null @('wad/x.ps1')
    Assert-Equal 'Distribution modifiee' $nothing.Overall 'Fichier non declare sans autre fichier examine';Assert-False $nothing.DistributionSignatureValid
}
Test-Case 'D116' 'Aucune action proposee ne desactive une protection Windows' {
    $weaken='(?i)Unblock-File|ExecutionPolicy|Bypass|Set-MpPreference|Add-MpPreference|SmartScreen|Zone\.Identifier|desactiv|ignorer la signature'
    $broken=@(& $script:RelSignedFiles);$broken[1].SignatureStatus='HashMismatch'
    $modified=@(& $script:RelSignedFiles);$modified[0].ActualSha256=(Get-DomeniaTextHash 'x')
    $unknown=@(& $script:RelSignedFiles|ForEach-Object{$_.ActualSha256='';$_})
    $verdicts=@(
        (Get-DomeniaSignatureVerdict (& $script:RelSignedFiles) $script:RelPin $script:RelManifestSig)
        (Get-DomeniaSignatureVerdict (& $script:RelSignedFiles) $script:RelPin)
        (Get-DomeniaSignatureVerdict $broken $script:RelPin $script:RelManifestSig)
        (Get-DomeniaSignatureVerdict $modified $script:RelPin $script:RelManifestSig)
        (Get-DomeniaSignatureVerdict $unknown $script:RelPin)
        (Get-DomeniaSignatureVerdict @() $script:RelPin)
    )
    Assert-Equal 6 @($verdicts|ForEach-Object{$_.Overall}|Sort-Object -Unique).Count 'Six verdicts differents examines'
    foreach($v in $verdicts){Assert-False ($v.NextAction -match $weaken) ('Action affaiblissante : '+$v.NextAction)}
    $source=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Release.Model.ps1'),[Text.Encoding]::UTF8)
    $safety=Test-DomeniaTransportCodeSafety $source;Assert-True $safety.Safe ($safety.Findings -join ', ')
    Assert-False ($source -match '(?i)Unblock-File|Set-ExecutionPolicy|Set-AuthenticodeSignature|New-SelfSignedCertificate|Import-Certificate') 'La regle lit des statuts ; elle ne signe ni ne debloque rien'
}

# ---------------------------------------------------------------- D117
Test-Case 'D117' 'Version lue dans le fichier livre et liee a son empreinte' {
    $manifest=[pscustomobject]@{Build=$script:RelBuild;Files=@([pscustomobject]@{Path='Domenia.exe';Sha256=$script:RelExeSha;Bytes=26624})}
    $read=@{'Domenia.exe'=[pscustomobject]@{Sha256=$script:RelExeSha;FileVersion='1.0.0.1'}}
    $row=(Get-DomeniaComponentInventory $manifest $null $read).Rows[0]
    Assert-True $row.Bound;Assert-Equal '1.0.0.1' $row.Version;Assert-Equal 'Ressource de version du fichier livre' $row.VersionSource
    Assert-True ($row.Display -match '3535A6CBCEEA') 'Affichage relie a l empreinte du fichier';Assert-Equal 26624 $row.Bytes
    $generic=New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $generic.Add('Domenia.exe',[pscustomobject]@{Sha256=$script:RelExeSha;FileVersion='1.0.0.1'})
    Assert-Equal '1.0.0.1' (Get-DomeniaComponentInventory $manifest $null $generic).Rows[0].Version 'Versions lues passees en dictionnaire generique'
    $viaContract=(Get-DomeniaComponentInventory $manifest (& $script:RelContract)).Rows[0]
    Assert-True $viaContract.Bound;Assert-Equal '1.0.0.1' $viaContract.Version;Assert-Equal 'Interne' $viaContract.Licence;Assert-Equal 'Non evaluees' $viaContract.Vulnerabilities
    $coreManifest=[pscustomobject]@{Build=$script:RelBuild;Files=@([pscustomobject]@{Path='wad/Domenia-Core.ps1';Sha256=(Get-DomeniaTextHash 'core');Bytes=10})}
    $core=(Get-DomeniaComponentInventory $coreManifest (& $script:RelContract)).Rows[0];Assert-True $core.Bound;Assert-Equal $script:RelBuild $core.Version;Assert-True ($core.VersionSource -match 'manifeste')
}
Test-Case 'D117' 'Une version d un autre fichier ou d un simple nom de paquet n est pas affichee' {
    $manifest=[pscustomobject]@{Build=$script:RelBuild;Files=@([pscustomobject]@{Path='wad/Microsoft.ActiveDirectory.Management.dll';Sha256=(Get-DomeniaTextHash 'dll livree');Bytes=1})}
    $otherFile=@{'wad/Microsoft.ActiveDirectory.Management.dll'=[pscustomobject]@{Sha256=(Get-DomeniaTextHash 'autre dll');FileVersion='10.0.1'}}
    $a=(Get-DomeniaComponentInventory $manifest $null $otherFile).Rows[0];Assert-False $a.Bound;Assert-Equal '' $a.Version;Assert-True ($a.Note -match 'empreinte differe')
    $byName=[pscustomobject]@{Components=@([pscustomobject]@{Path='wad/Microsoft.ActiveDirectory.Management.dll';Name='ActiveDirectory';VersionPolicy='Distinct';Version='10.0.26100'})}
    $b=(Get-DomeniaComponentInventory $manifest $byName).Rows[0];Assert-False $b.Bound;Assert-True ($b.Note -match 'nom de paquet');Assert-True ($b.Display -match 'non reliee')
    $otherSha=[pscustomobject]@{Components=@([pscustomobject]@{Path='wad/Microsoft.ActiveDirectory.Management.dll';Name='ActiveDirectory';VersionPolicy='Distinct';Version='10.0.26100';Sha256=(Get-DomeniaTextHash 'x')})}
    Assert-False (Get-DomeniaComponentInventory $manifest $otherSha).Rows[0].Bound 'Version declaree pour une autre empreinte'
    $bare=Get-DomeniaComponentInventory $manifest;Assert-False $bare.Rows[0].Bound 'Un binaire n herite jamais du build';Assert-False $bare.Complete;Assert-Equal 1 $bare.Unbound
    Assert-False (Get-DomeniaComponentInventory $manifest $null @{'wad/Microsoft.ActiveDirectory.Management.dll'=[pscustomobject]@{FileVersion='10.0.1'}}).Rows[0].Bound 'Version lue sans empreinte'
}
Test-Case 'D117' 'Inventaire du PROD livre : chaque version affichee est reliee a un fichier' {
    $prod=& $script:RelReadJson 'tools\prod-manifest.json'
    $inv=Get-DomeniaComponentInventory $prod (& $script:RelContract)
    Assert-Equal @($prod.Files).Count @($inv.Rows).Count
    $exe=@($inv.Rows|Where-Object{$_.Path -eq 'Domenia.exe'})[0]
    Assert-True $exe.Bound 'Empreinte du contrat egale a celle du manifeste (Domenia.exe conserve a l octet)';Assert-Equal '1.0.0.1' $exe.Version
    Assert-Equal ([string]$prod.Build) @($inv.Rows|Where-Object{$_.Path -eq 'wad/Domenia-Core.ps1'})[0].Version
    foreach($row in @($inv.Rows)){
        if($row.Bound){Assert-Equal 64 $row.Sha256.Length $row.Path}else{Assert-Equal '' $row.Version ('Version sans lien : '+$row.Path)}
    }
    Assert-False @($inv.Rows|Where-Object{$_.Path -eq 'wad/PsExec.exe'})[0].Bound 'PsExec sans version liee a son empreinte'
}

# ---------------------------------------------------------------- D118
Test-Case 'D118' 'Configuration, preference, cache et recu : un chemin et des droits par categorie' {
    $l=Get-DomeniaStorageLayout -Mode UserLocal -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -Writable @{Preference=$true;Cache=$true;Receipt=$true}
    Assert-True $l.Ready ($l.Errors -join ' | ');Assert-Equal 'UserLocal' $l.Mode;Assert-Equal 'Explicite' $l.ModeSource
    $by=@{};foreach($c in $l.Categories){$by[$c.Category]=$c}
    Assert-Equal 'C:\Program Files\Domenia\wad\Domenia.config.json' $by['Configuration'].Path;Assert-False $by['Configuration'].WriteRequired
    Assert-Equal 'C:\Users\agent\AppData\Local\Domenia\Data\Preferences' $by['Preference'].Path
    Assert-Equal 'C:\Users\agent\AppData\Local\Domenia\Data' $by['Cache'].Path
    Assert-Equal 'C:\Users\agent\AppData\Local\Domenia\Receipts' $by['Receipt'].Path
    Assert-Equal 4 @($l.Categories|ForEach-Object{$_.Path}|Sort-Object -Unique).Count 'Quatre emplacements distincts'
    Assert-True ($by['Receipt'].Rights -match 'aucun recu reecrit');Assert-True (@($by['Preference'].ReadAlsoFrom) -contains 'C:\Program Files\Domenia\wad') 'Ancien emplacement lu seulement'
    $p=Get-DomeniaStorageLayout -Mode Portable -InstallRoot 'E:\Outils\Domenia' -UserLocalRoot $script:RelProfile -Writable @{Preference=$true;Cache=$true;Receipt=$true}
    Assert-True $p.Ready;Assert-Equal 'E:\Outils\Domenia\wad\data' $p.DataRoot 'Mode portable : wad\data, comme le coeur'
    Assert-Equal 'C:\Users\agent\AppData\Local\Domenia\Receipts' @($p.Categories|Where-Object{$_.Category -eq 'Receipt'})[0].Path 'Recus toujours dans le profil local'
}
Test-Case 'D118' 'Compte standard ou dossier non inscriptible : erreur explicite, aucune bascule' {
    $p=Get-DomeniaStorageLayout -Mode Portable -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -Writable @{Preference=$false;Cache=$false;Receipt=$true}
    Assert-False $p.Ready;Assert-Equal 'Portable' $p.Mode 'Le mode demande est conserve';Assert-Equal 'C:\Program Files\Domenia\wad\data' $p.DataRoot 'Aucun repli vers le profil'
    foreach($c in @($p.Categories|Where-Object{$_.Category -in @('Preference','Cache')})){
        Assert-Equal 'Non inscriptible' $c.State $c.Category;Assert-Equal '' $c.Fallback
        Assert-True ($c.Error -match [regex]::Escape($c.Path)) 'Le chemin demande est nomme';Assert-True ($c.Error -match 'Aucune bascule silencieuse')
    }
    $byPath=Get-DomeniaStorageLayout -Mode UserLocal -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -Writable @{'C:\Users\agent\AppData\Local\Domenia\Data'=$false;Preference=$true;Receipt=$true}
    Assert-Equal 'Non inscriptible' @($byPath.Categories|Where-Object{$_.Category -eq 'Cache'})[0].State 'Droit observe par chemin'
    $unknown=Get-DomeniaStorageLayout -Mode UserLocal -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile
    Assert-False $unknown.Ready 'Ecriture non verifiee : pas pret';Assert-Equal 3 @($unknown.Categories|Where-Object{$_.State -eq 'Non verifie'}).Count
    $noProfile=Get-DomeniaStorageLayout -Mode UserLocal -InstallRoot $script:RelInstall -UserLocalRoot '' -Writable @{Preference=$true;Cache=$true;Receipt=$true}
    Assert-False $noProfile.Ready;Assert-True (($noProfile.Errors -join ' ') -match 'Aucun dossier de remplacement')
    Assert-Equal '' @($noProfile.Categories|Where-Object{$_.Category -eq 'Cache'})[0].Path 'Aucun chemin invente'
}
Test-Case 'D118' 'Droits observes par categorie et par chemin : la reponse la plus restrictive l emporte' {
    $data='C:\Users\agent\AppData\Local\Domenia\Data'
    foreach($writable in @(@{Cache=$true;$data=$false;Preference=$true;Receipt=$true},@{Cache=$false;$data=$true;Preference=$true;Receipt=$true})){
        $l=Get-DomeniaStorageLayout -Mode UserLocal -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -Writable $writable
        $cache=@($l.Categories|Where-Object{$_.Category -eq 'Cache'})[0]
        Assert-Equal 'Non inscriptible' $cache.State 'Un refus observe n est jamais couvert par une autorisation';Assert-False $l.Ready;Assert-False $cache.Writable
    }
    $generic=New-Object 'System.Collections.Generic.Dictionary[string,bool]'
    $generic.Add('Preference',$true);$generic.Add('Cache',$true);$generic.Add('Receipt',$true)
    Assert-True (Get-DomeniaStorageLayout -Mode UserLocal -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -Writable $generic).Ready 'Droits passes en dictionnaire generique'
    $generic.Add($data,$false)
    Assert-False (Get-DomeniaStorageLayout -Mode UserLocal -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -Writable $generic).Ready 'Refus par chemin dans un dictionnaire generique'
}
Test-Case 'D118' 'Mode Compatible deduit des donnees presentes et annonce, jamais des droits' {
    $c=Get-DomeniaStorageLayout -Mode Compatible -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -PortableHasData $true -Writable @{Preference=$false;Cache=$false;Receipt=$true}
    Assert-Equal 'Portable' $c.Mode 'Un dossier protege ne fait pas basculer vers le profil';Assert-Equal 'Deduit' $c.ModeSource;Assert-False $c.Ready
    Assert-Equal 1 @($c.Notices).Count
    $u=Get-DomeniaStorageLayout -Mode Compatible -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -PortableHasData $false -Writable @{Preference=$true;Cache=$true;Receipt=$true}
    Assert-Equal 'UserLocal' $u.Mode;Assert-True $u.Ready;Assert-True ($u.Notices[0] -match 'Compatible')
}
Test-Case 'D118' 'Base active sur un emplacement reseau refusee' {
    $unc=Get-DomeniaStorageLayout -Mode Portable -InstallRoot '\\srv\outils\Domenia' -UserLocalRoot $script:RelProfile -Writable @{Preference=$true;Cache=$true;Receipt=$true}
    Assert-False $unc.Ready;Assert-Equal 'Distant refuse' @($unc.Categories|Where-Object{$_.Category -eq 'Cache'})[0].State
    $mapped=Get-DomeniaStorageLayout -Mode UserLocal -InstallRoot $script:RelInstall -UserLocalRoot 'H:\Profil' -NetworkDrives @('H:') -Writable @{Preference=$true;Cache=$true;Receipt=$true}
    Assert-False $mapped.Ready;Assert-Equal 3 @($mapped.Categories|Where-Object{$_.State -eq 'Distant refuse'}).Count
}

Test-Case 'D118' 'Six zones sous Cache, toujours quatre categories' {
    foreach($mode in @('UserLocal','Portable')){
        $l=Get-DomeniaStorageLayout -Mode $mode -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -Writable @{Preference=$true;Cache=$true}
        Assert-Equal 4 @($l.Categories).Count
        $cache=@($l.Categories | Where-Object {$_.Category -eq 'Cache'})[0]
        Assert-Equal 'Logs,Backups,Diagnostics,Exports,Legacy,Domains' (($cache.Areas | ForEach-Object {$_.Name}) -join ',')
        foreach($area in $cache.Areas){Assert-Equal ($l.DataRoot+'\'+$area.Name) $area.Path}
        foreach($category in @($l.Categories | Where-Object {$_.Category -ne 'Cache'})){Assert-False ($null -ne $category.PSObject.Properties['Areas'])}
        Assert-True (@($cache.Areas | Where-Object {$_.Name -eq 'Backups'})[0].Note -match '<dossier de la base>')
        Assert-Equal 'Non verifie' @($l.Categories | Where-Object {$_.Category -eq 'Receipt'})[0].State
    }
    $none=Get-DomeniaStorageLayout -UserLocalRoot '' -InstallRoot $script:RelInstall
    foreach($area in @($none.Categories | Where-Object {$_.Category -eq 'Cache'})[0].Areas){Assert-Equal '' $area.Path}
}
function New-PreferencePlanFixture {
    $l=Get-DomeniaStorageLayout -Mode Portable -InstallRoot $script:RelInstall -UserLocalRoot $script:RelProfile -Writable @{Preference=$true;Cache=$true}
    $old=[pscustomobject]@{Path=($l.DataRoot+'\Domenia.settings.json');Exists=$true;Bytes=24L;IsReparse=$false;ValidJson=$true}
    $new=[pscustomobject]@{Path=($l.DataRoot+'\Preferences\Domenia.settings.json');Exists=$false;Bytes=0L;IsReparse=$false;ValidJson=$false}
    return [pscustomobject]@{Layout=$l;Old=$old;New=$new}
}
Test-Case 'D118' 'Copie unique des preferences et idempotence sans effacer l original' {
    $f=New-PreferencePlanFixture
    $p=Get-DomeniaPreferenceMigrationPlan $f.Layout @($f.Old,$f.New)
    Assert-Equal 0 @($p.Errors).Count;Assert-Equal 1 @($p.Steps).Count;Assert-Equal 'Copier' $p.Steps[0].Action
    Assert-Equal $f.Old.Path $p.Steps[0].Source;Assert-Equal $f.New.Path $p.Steps[0].Target
    $f.New.Exists=$true
    $again=Get-DomeniaPreferenceMigrationPlan $f.Layout @($f.Old,$f.New)
    Assert-Equal 'Conserver' $again.Steps[0].Action
    Assert-Equal 0 @($again.Steps | Where-Object {$_.Action -in @('Copier','Supprimer','Deplacer')}).Count
    Assert-True $f.Old.Exists 'Aucune mutation des observations'
}
Test-Case 'D118' 'JSON invalide, taille excessive ou lien : source ignoree' {
    foreach($case in @('Invalid','Oversized','Reparse','UnknownSize')){
        $f=New-PreferencePlanFixture
        switch($case){'Invalid'{$f.Old.ValidJson=$false};'Oversized'{$f.Old.Bytes=1MB+1};'Reparse'{$f.Old.IsReparse=$true};'UnknownSize'{$f.Old.Bytes=-1L}}
        $p=Get-DomeniaPreferenceMigrationPlan $f.Layout @($f.Old,$f.New)
        Assert-Equal 'Ignorer' $p.Steps[0].Action $case
    }
    $f=New-PreferencePlanFixture;$f.Old.Bytes=1MB
    Assert-Equal 'Copier' (Get-DomeniaPreferenceMigrationPlan $f.Layout @($f.Old,$f.New)).Steps[0].Action 'Borne exacte autorisee'
}
Test-Case 'D118' 'Fichiers livres et autre mode ignores, aucun nom arbitraire migre' {
    $f=New-PreferencePlanFixture
    $files=@($f.New)
    foreach($path in @(($script:RelInstall+'\wad\Domenia.theme.cfg'),($script:RelInstall+'\wad\Domenia.ui-profile.cfg'),($script:RelInstall+'\wad\Domenia.settings.json'),($script:RelProfile+'\Domenia\Data\Domenia.settings.json'),($f.Layout.DataRoot+'\Domenia.config.json'))){
        $files+=@([pscustomobject]@{Path=$path;Exists=$true;Bytes=24L;IsReparse=$false;ValidJson=$true})
    }
    $p=Get-DomeniaPreferenceMigrationPlan $f.Layout $files
    Assert-Equal 5 @($p.Steps).Count
    foreach($step in $p.Steps){Assert-Equal 'Ignorer' $step.Action;Assert-Equal '' $step.Target}
}
Test-Case 'D118' 'Droits refuses ou inconnus : aucun autre emplacement propose' {
    foreach($state in @('Non inscriptible','Non verifie','Distant refuse')){
        $f=New-PreferencePlanFixture
        $preference=@($f.Layout.Categories | Where-Object {$_.Category -eq 'Preference'})[0];$preference.State=$state
        $p=Get-DomeniaPreferenceMigrationPlan $f.Layout @($f.Old,$f.New)
        Assert-Equal 'Refuser' $p.Steps[0].Action;Assert-Equal $f.New.Path $p.Steps[0].Target
        Assert-True ($p.Errors[0] -match [regex]::Escape($preference.Path))
        Assert-Equal 0 @($p.Steps | Where-Object {$_.Action -in @('Copier','Supprimer','Deplacer')}).Count
    }
}
Test-Case 'D118' 'Destination existante preservee meme si la source est invalide' {
    $f=New-PreferencePlanFixture;$f.New.Exists=$true;$f.Old.ValidJson=$false
    Assert-Equal 'Conserver' (Get-DomeniaPreferenceMigrationPlan $f.Layout @($f.Old,$f.New)).Steps[0].Action
}
Test-Case 'D118' 'Observations incompletes, dupliquees ou disposition incoherente refusent la copie' {
    $f=New-PreferencePlanFixture
    Assert-Equal 'Refuser' (Get-DomeniaPreferenceMigrationPlan $f.Layout @($f.Old)).Steps[0].Action
    Assert-Equal 'Refuser' (Get-DomeniaPreferenceMigrationPlan $f.Layout @($f.Old,$f.Old,$f.New)).Steps[0].Action
    @($f.Layout.Categories | Where-Object {$_.Category -eq 'Preference'})[0].Path='C:\Autre\Preferences'
    Assert-Equal 'Refuser' (Get-DomeniaPreferenceMigrationPlan $f.Layout @($f.Old,$f.New)).Steps[0].Action
}


# ---------------------------------------------------------------- D119
Test-Case 'D119' 'Kit reel : jetons, vocabulaire et version, conformes au lecteur du runtime' {
    $design=& $script:RelReadJson 'wad\modules\SupportSuite.UI.json'
    $experience=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Experience.Model.ps1'),[Text.Encoding]::UTF8)
    $list=[regex]::Match($experience,'foreach\(\$required in @\(([^)]*)\)\)')
    Assert-True $list.Success 'Liste des jetons requis introuvable dans Get-SuiteDesign'
    $required=@([regex]::Matches($list.Groups[1].Value,"'([A-Za-z]+)'")|ForEach-Object{$_.Groups[1].Value})
    Assert-True ($required.Count -ge 20) 'Jetons requis lus'
    $kit=Get-DomeniaSuiteKitManifest $design $required
    Assert-True $kit.Valid ($kit.Errors -join ' | ');Assert-Equal 'PARTIEL' $kit.Status;Assert-True ($kit.KitVersion -match '^SupportSuite/1\+[0-9A-F]{12}$')
    Assert-Equal @($design.Palettes.Light.PSObject.Properties).Count @($kit.Tokens|Where-Object{$_.Theme -eq 'Light'}).Count
    Assert-Equal ([string]$design.Vocabulary.Idle) @($kit.Vocabulary|Where-Object{$_.Key -eq 'Idle'})[0].Text
    Assert-Equal (Get-DomeniaSuiteKitManifest (& $script:RelReadJson 'wad\modules\SupportSuite.UI.json') $required).KitVersion $kit.KitVersion 'Version stable pour un meme contenu'
    Assert-True ($kit.Limit -match 'Pesto et FILPRO') 'Limite declaree'
}
Test-Case 'D119' 'Un changement du kit change sa version et exige une validation dans chaque produit' {
    $kit=Get-DomeniaSuiteKitManifest (& $script:RelReadJson 'wad\modules\SupportSuite.UI.json')
    $products=@($kit.Products);Assert-True ($products.Count -ge 3) 'Domenia et deux autres produits declares'
    $all=@($products|ForEach-Object{[pscustomobject]@{Product=$_;KitVersion=$kit.KitVersion;Passed=$true}})
    Assert-True (Test-DomeniaSuiteKitDiffusion $kit $all).Allowed
    $only=Test-DomeniaSuiteKitDiffusion $kit @($all[0]);Assert-False $only.Allowed;Assert-Equal ($products.Count-1) @($only.Missing).Count
    Assert-False (Test-DomeniaSuiteKitDiffusion $kit @($all[0],$all[1],[pscustomobject]@{Product=$products[2];KitVersion=$kit.KitVersion;Passed=$false})).Allowed 'Validation en echec'
    $changed=& $script:RelReadJson 'wad\modules\SupportSuite.UI.json';$changed.Palettes.Dark.AccentColor='#0A70D0'
    $kit2=Get-DomeniaSuiteKitManifest $changed
    Assert-True ($kit2.KitVersion -cne $kit.KitVersion) 'Nouvelle version de kit'
    Assert-False (Test-DomeniaSuiteKitDiffusion $kit2 $all).Allowed 'Les validations de l ancien kit ne comptent pas'
}
Test-Case 'D119' 'Kit incoherent refuse' {
    $design=& $script:RelReadJson 'wad\modules\SupportSuite.UI.json';$design.Palettes.Dark.PSObject.Properties.Remove('LogBg')
    Assert-True (((Get-DomeniaSuiteKitManifest $design).Errors -join ' ') -match 'Jeton absent du theme sombre : LogBg')
    $bad=& $script:RelReadJson 'wad\modules\SupportSuite.UI.json';$bad.Palettes.Light.TextColor='bleu'
    Assert-False (Get-DomeniaSuiteKitManifest $bad).Valid 'Couleur invalide'
    Assert-False (Get-DomeniaSuiteKitManifest (& $script:RelReadJson 'wad\modules\SupportSuite.UI.json') @('JetonInexistant')).Valid 'Jeton requis absent'
    Assert-False (Get-DomeniaSuiteKitManifest $null).Valid
    Assert-False (Test-DomeniaSuiteKitDiffusion (Get-DomeniaSuiteKitManifest $null) @()).Allowed
}

# ---------------------------------------------------------------- D120
Test-Case 'D120' 'Connecteur absent, desactive ou non livre : masque' {
    $none=Get-DomeniaConnectorCatalog ([pscustomobject]@{Auth=[pscustomobject]@{}})
    Assert-Equal 0 $none.VisibleCount;Assert-False @($none.Connectors|Where-Object{$_.Name -eq 'Wapt'})[0].Visible
    $off=Get-DomeniaConnectorCatalog ([pscustomobject]@{WAPT=[pscustomobject]@{Enabled=$false;ServerUrl='https://wapt.example.test'}})
    Assert-Equal 'Masque' @($off.Connectors|Where-Object{$_.Name -eq 'Wapt'})[0].State 'Valeur par defaut du coeur : WAPT.Enabled = false'
    $glpi=@((Get-DomeniaConnectorCatalog ([pscustomobject]@{GLPI=[pscustomobject]@{Enabled=$true;ServerUrl='https://glpi.example.test'}})).Connectors|Where-Object{$_.Name -eq 'Glpi'})[0]
    Assert-False $glpi.Visible;Assert-True ($glpi.Reason -match 'non livre')
    $u=Test-DomeniaConnectorAvailable $none 'Wapt';Assert-False $u.Allowed;Assert-False $u.Visible
    Assert-False (Test-DomeniaConnectorAvailable $none 'Inconnu').Visible
}
Test-Case 'D120' 'Connecteur refuse ou injoignable : indisponible et visible, l annuaire reste lu' {
    foreach($outcome in @('Refuse','Injoignable')){
        $cat=Get-DomeniaConnectorCatalog (& $script:RelWaptOn) @{Wapt=$outcome}
        $w=@($cat.Connectors|Where-Object{$_.Name -eq 'Wapt'})[0]
        Assert-Equal 'Indisponible' $w.State $outcome;Assert-True $w.Visible;Assert-True ($w.Reason -match 'annuaire reste utilisable')
        Assert-False ($w.Reason -match 'n existe pas') 'Un refus ne dit jamais que la donnee n existe pas'
        $plan=Get-DomeniaSourceReadPlan $cat 'Explicit' @('Wapt')
        Assert-Equal 'Annuaire' (@($plan.Reads|ForEach-Object{$_.Source}) -join ',');Assert-Equal 'Wapt' $plan.Skipped[0].Source
    }
    $generic=New-Object 'System.Collections.Generic.Dictionary[string,string]';$generic.Add('Wapt','Refuse')
    Assert-Equal 'Indisponible' @((Get-DomeniaConnectorCatalog (& $script:RelWaptOn) $generic).Connectors|Where-Object{$_.Name -eq 'Wapt'})[0].State 'Etats passes en dictionnaire generique'
}
Test-Case 'D120' 'Aucune collecte automatique et aucune ecriture par un connecteur' {
    $cat=Get-DomeniaConnectorCatalog (& $script:RelWaptOn) @{Wapt='Disponible'}
    Assert-True (Test-DomeniaConnectorAvailable $cat 'Wapt' 'Explicit' 'Read').Allowed
    foreach($trigger in @('Selection','Startup','Timer')){Assert-False (Test-DomeniaConnectorAvailable $cat 'Wapt' $trigger 'Read').Allowed $trigger}
    Assert-False (Test-DomeniaConnectorAvailable $cat 'Wapt' 'Explicit' 'Write').Allowed 'Lecture seule'
    Assert-Equal 'Annuaire' (@((Get-DomeniaSourceReadPlan $cat 'Selection' @('Wapt')).Reads|ForEach-Object{$_.Source}) -join ',')
    Assert-Equal 'Annuaire,Wapt' (@((Get-DomeniaSourceReadPlan $cat 'Explicit' @('Wapt')).Reads|ForEach-Object{$_.Source}) -join ',')
    $w=@($cat.Connectors|Where-Object{$_.Name -eq 'Wapt'})[0]
    Assert-True $w.ReadOnly;Assert-False $w.CanWrite;Assert-Equal 'WaptHost/1' $w.MappingVersion;Assert-Equal 'WAPT https://wapt.example.test' $w.Provenance
}
Test-Case 'D120' 'Aucun etat de connecteur, meme mal forme, n empeche la lecture de l annuaire' {
    # The directory line is structural; what is exercised here is that no connector state, valid or malformed, makes the
    # read plan throw (which would block the directory at the call site) or start a collection on its own.
    $configs=@($null,'texte',([pscustomobject]@{WAPT='texte'}),([pscustomobject]@{WAPT=[pscustomobject]@{Enabled=$false}}),([pscustomobject]@{WAPT=[pscustomobject]@{Enabled='peut-etre';ServerUrl=$null}}),(& $script:RelWaptOn),(& $script:RelWaptOn 'http://wapt.example.test'),(& $script:RelWaptOn 'https://admin:S3cretX@wapt.example.test'),([pscustomobject]@{WAPT=[pscustomobject]@{Enabled=$true;ServerUrl='https://wapt.example.test';Password='factice'}}),(@{WAPT=@{Enabled=$true;ServerUrl='https://wapt.example.test:99999'}}))
    foreach($config in $configs){foreach($outcome in @('','Disponible','Refuse','Injoignable','Delai depasse')){foreach($trigger in @('Explicit','Selection','Startup','Timer')){
        $status=@{};if($outcome){$status['Wapt']=$outcome}
        $plan=$null
        try{$plan=Get-DomeniaSourceReadPlan (Get-DomeniaConnectorCatalog $config $status) $trigger @('Wapt','Glpi','Intune','ConfigMgr','',$null)}
        catch{throw ('Le plan de lecture echoue ('+$outcome+', '+$trigger+') : '+$_.Exception.Message)}
        Assert-True $plan.DirectoryIncluded;Assert-Equal 'Annuaire' $plan.Reads[0].Source
        if($trigger -ne 'Explicit'){Assert-Equal 1 @($plan.Reads).Count ('Collecte automatique : '+$trigger)}
    }}}
    Assert-Equal 'Annuaire' (@((Get-DomeniaSourceReadPlan $null 'Explicit' @('Wapt')).Reads|ForEach-Object{$_.Source}) -join ',') 'Catalogue absent'
}
Test-Case 'D120' 'Configuration non sure refusee sans recopier le secret : http, identifiant dans l adresse, parametres' {
    $urls=[ordered]@{
        'https://admin:S3cretX@wapt.example.test'='Secret'
        'https://admin@wapt.example.test'='Secret'
        'https://:S3cretX@wapt.example.test:8443/api'='Secret'
        'http://admin:S3cretX@wapt.example.test'='Secret'
        'admin:S3cretX@wapt.example.test'='Secret'
        'https://wapt.example.test/?token=S3cretX'='Parametres'
        'https://wapt.example.test/api#S3cretX'='Parametres'
        'http://wapt.example.test'='NonChiffree'
        'https://wapt.example.test S3cretX'='Illisible'
        'https://wapt.example.test:0'='Illisible'
        ''='Absente'
    }
    foreach($url in @($urls.Keys)){
        $endpoint=ConvertTo-DomeniaConnectorEndpoint $url
        Assert-Equal $urls[$url] $endpoint.Problem $url;Assert-False $endpoint.Usable $url
        $cat=Get-DomeniaConnectorCatalog (& $script:RelWaptOn $url) @{Wapt='Disponible'}
        $w=@($cat.Connectors|Where-Object{$_.Name -eq 'Wapt'})[0]
        Assert-Equal 'Indisponible' $w.State $url;Assert-True $w.Visible $url
        Assert-False (Test-DomeniaConnectorAvailable $cat 'Wapt' 'Explicit' 'Read').Allowed ('Lecture permise malgre : '+$url)
        $shown=($w|ConvertTo-Json -Depth 4)+' '+($cat|ConvertTo-Json -Depth 5)
        Assert-False ($shown -match 'S3cretX') ('Secret recopie : '+$url);Assert-False ($shown -match 'admin:') ('Identifiant recopie : '+$url)
        if($urls[$url] -eq 'Secret'){Assert-True ($w.Reason -match 'Secret') $url}
    }
    $good=@((Get-DomeniaConnectorCatalog (& $script:RelWaptOn 'https://WAPT.example.test:8443/wapt') @{Wapt='Disponible'}).Connectors|Where-Object{$_.Name -eq 'Wapt'})[0]
    Assert-Equal 'Disponible' $good.State;Assert-Equal 'https://wapt.example.test:8443' $good.Server;Assert-Equal 'WAPT https://wapt.example.test:8443' $good.Provenance
    $secret=@((Get-DomeniaConnectorCatalog ([pscustomobject]@{WAPT=[pscustomobject]@{Enabled=$true;ServerUrl='https://wapt.example.test';ApiKey='factice'}}) @{Wapt='Disponible'}).Connectors|Where-Object{$_.Name -eq 'Wapt'})[0]
    Assert-Equal 'Indisponible' $secret.State;Assert-True ($secret.Reason -match 'Secret')
    $rec=[pscustomobject]@{computer_fqdn='pc-001.example.test';host_status='OK';last_seen_on='2026-10-01T08:00:00Z'}
    $facts=(ConvertFrom-DomeniaWaptHost $rec $script:RelNow 'https://admin:S3cretX@wapt.example.test' 'pc-001.example.test').Facts
    Assert-Equal 0 @($facts|Where-Object{$_.Source -match 'S3cretX|admin'}).Count 'Source des faits sans secret'
}
Test-Case 'D120' 'Fiche WAPT en lecture seule : donnee declaree, anciennete et correspondance' {
    $rec=[pscustomobject]@{uuid='4C4C4544-0000-1000-8000-B1C04F000001';computer_fqdn='pc-001.example.test';computer_name='PC-001';host_status='OK';os_name='Windows 11 Enterprise';os_version='10.0.26100';last_seen_on='2026-10-01T08:00:00Z'}
    $r=ConvertFrom-DomeniaWaptHost $rec $script:RelNow 'https://wapt.example.test' 'PC-001.example.test'
    Assert-True $r.Found;Assert-True $r.Attributed;Assert-False $r.Stale;Assert-True $r.ReadOnly
    $state=@($r.Facts|Where-Object{$_.Fait -eq 'Etat WAPT'})[0];Assert-Equal 'Constate' $state.Etat;Assert-True ($state.Limite -match 'pas une lecture du poste')
    $old=$rec.PSObject.Copy();$old.last_seen_on='2026-09-01T08:00:00Z'
    $s=ConvertFrom-DomeniaWaptHost $old $script:RelNow '' 'pc-001.example.test';Assert-True $s.Stale
    Assert-True (@($s.Facts|Where-Object{$_.Fait -eq 'Derniere remontee WAPT'})[0].Valeur -match 'ancienne')
    $none=ConvertFrom-DomeniaWaptHost $null $script:RelNow;Assert-False $none.Found;Assert-Equal 'Inconnu' $none.Facts[0].Etat;Assert-False ($none.Facts[0].Valeur -match 'panne')
    $other=ConvertFrom-DomeniaWaptHost $rec $script:RelNow '' 'pc-002.example.test'
    Assert-False $other.Attributed;Assert-Equal 1 @($other.Facts).Count 'Aucune donnee attribuee a un autre poste';Assert-Equal 'Inconnu' $other.Facts[0].Etat
    $unchecked=ConvertFrom-DomeniaWaptHost $rec $script:RelNow;Assert-True ($null -eq $unchecked.Attributed);Assert-True (@($unchecked.Facts|Where-Object{$_.Limite -match 'non verifiee'}).Count -ge 1)
}
Test-Case 'D120' 'Donnee WAPT ancienne ou non rapprochee du poste AD : estimee, jamais constatee' {
    $rec=[pscustomobject]@{computer_fqdn='pc-001.example.test';computer_name='PC-001';host_status='OK';os_name='Windows 11';os_version='10.0.26100';last_seen_on='2026-01-01T00:00:00Z'}
    $stale=ConvertFrom-DomeniaWaptHost $rec $script:RelNow
    Assert-Equal 'Estime' @($stale.Facts|Where-Object{$_.Fait -eq 'Etat WAPT'})[0].Etat 'Neuf mois, poste non rapproche'
    Assert-Equal 'Estime' @($stale.Facts|Where-Object{$_.Fait -eq 'Systeme declare a WAPT'})[0].Etat
    $recent=$rec.PSObject.Copy();$recent.last_seen_on='2026-10-01T08:00:00Z'
    Assert-Equal 'Estime' @((ConvertFrom-DomeniaWaptHost $recent $script:RelNow).Facts|Where-Object{$_.Fait -eq 'Etat WAPT'})[0].Etat 'Recent mais correspondance non verifiee'
    $matchedOld=ConvertFrom-DomeniaWaptHost $rec $script:RelNow '' 'pc-001.example.test'
    Assert-Equal 'Estime' @($matchedOld.Facts|Where-Object{$_.Fait -eq 'Etat WAPT'})[0].Etat 'Rapproche mais ancien'
    Assert-Equal 'Constate' @($matchedOld.Facts|Where-Object{$_.Fait -eq 'Derniere remontee WAPT'})[0].Etat 'La date de remontee reste un fait du poste rapproche'
    Assert-Equal 'Constate' @((ConvertFrom-DomeniaWaptHost $recent $script:RelNow '' 'pc-001.example.test').Facts|Where-Object{$_.Fait -eq 'Etat WAPT'})[0].Etat 'Recent et rapproche'
    Assert-True (ConvertFrom-DomeniaWaptHost $recent $script:RelNow '' 'PC-001.example.test.').Attributed 'Point final du nom AD ignore'
    $dotted=$recent.PSObject.Copy();$dotted.computer_fqdn='pc-001.example.test.'
    Assert-True (ConvertFrom-DomeniaWaptHost $dotted $script:RelNow '' 'pc-001.example.test').Attributed 'Point final du nom WAPT ignore'
}
