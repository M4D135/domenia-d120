#requires -Version 5.1
# Decoder parity and aggregation edge cases. Pure local objects; no endpoint or VM.
$ErrorActionPreference='Stop'
$modules=Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','Boards.Model','BoardFleet.Model','Probes.Model')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:checks=0
function Expect {param([bool]$Good,[string]$Name);$script:checks++;if(-not $Good){throw $Name}}
$now=[datetime]::UtcNow;$at=$now.ToString('o');$reader=New-DomeniaObservationReader
$catalog=@(Get-DomeniaProbeCatalog)
foreach($probe in $catalog){
    $cells=switch -Regex ($probe.Transform){
        '^GB$'{@('8589934592')};'^GBfromKB$'{@('8388608')};'^MB$'{@('4194304')};'^Mbps$'{@('1000000000')}
        '^DaysSince$'{@($now.AddDays(-10).ToString('o'))};'^Year$'{@('2024-05-15T12:00:00Z')};'^PercentFree$'{@('25','100')}
        '^Release$'{@('26100','1')};'^Map:'{@(($probe.Transform.Substring(4).Split(';')[0].Split('='))[0])};default{@('42')}
    }
    foreach($case in @('normal','zero','invalid','error','skipped','truncated','empty')){
        $rows=@(,@($cells));$count=2
        if($case -eq 'zero'){$rows=@(,@('0','100'));$count=0}
        if($case -eq 'invalid'){$rows=@(,@('bad'))}
        if($case -eq 'empty'){$rows=@()}
        $raw=[pscustomobject]@{CheckedUtc=$at;Count=$count;Rows=$rows;Error=$(if($case -eq 'error'){'refused'}else{''});Skipped=$(if($case -eq 'skipped'){'DomainController'}else{''});Truncated=($case -eq 'truncated')}
        $dict=@{};$dict[$probe.Id]=$raw
        $obs=$reader.Read((ConvertTo-Json -InputObject ([pscustomobject]@{Guid='g';CheckedUtc=$at;Probes=$dict}) -Depth 8 -Compress),$now)
        $legacy=@(Get-DomeniaProbeValues $probe $raw);$native=@(Get-DomeniaProbeValues $probe $obs.Probes[$probe.Id])
        Expect (($legacy|ConvertTo-Json -Compress) -ceq ($native|ConvertTo-Json -Compress)) ('decoder parity '+$probe.Id+' '+$case)
        if($probe.Transform -ne 'Release'){Expect ($null -eq $obs.Probes[$probe.Id].Rows) 'raw rows released after normalization'}
    }
}
# Multi-value rows retain their boundaries and order, and numeric parsing stays invariant.
$definition=[Domenia.Native.ProbeDefinition]@{Id='x';Mode='All';Transform='Number';QueryNumeric=$true}
$reader=[Domenia.Native.ObservationReader]::new([Domenia.Native.ProbeDefinition[]]@($definition))
$json=ConvertTo-Json -InputObject @{Probes=@{x=@{CheckedUtc=$at;Rows=@(@('1'),@('2'),@('1,5'),@('NaN'),@('Infinity'),@('0'));Count=6}}} -Depth 8 -Compress
$result=$reader.Read($json,$now).Probes['x']
Expect (($result.Values -join ',') -eq '1,2,0') 'all rows and invalid numeric input'
Expect ($result.IsFresh($now,30) -and -not $result.IsFresh($now.AddDays(31),30) -and -not $result.IsFresh($now.AddMinutes(-6),30)) 'own timestamp and future guard'
$samples=[Domenia.Native.ProbeSamples]::new();$samples.Add([object[]]@(0.0,2.0,2.0,10.0),$now);$samples.Skip()
Expect ($samples.Machines -eq 1 -and $samples.Skipped -eq 1 -and $samples.Numeric -and $samples.Sum -eq 14) 'sample coverage and zero'
Expect ($samples.CountRange(0,2) -eq 2 -and $samples.CountEqual(0) -eq 1) 'histogram boundaries'
$p=[pscustomobject]@{Id='n';Mode='First';Transform='Number';Name='Count';Category='Test'}
$m=Measure-DomeniaWidgetData -Probe $p -Samples $samples -Visual Bar
Expect ($m.Items[1].ExactValue -eq 2 -and $m.Items[1].Value -eq 2) 'exact numeric segment value'
$samples=[Domenia.Native.ProbeSamples]::new();$samples.Add([object[]]@('A','a','B','C','D','E','F','G','H','I'),$now)
$m=Measure-DomeniaWidgetData -Probe $p -Samples $samples -Visual Pie
Expect ($m.Items[0].Value -eq 2 -and $m.Items[-1].Label -eq 'Autres' -and $m.Items[-1].Excluded.Count -eq 8) 'category count and exact remaining categories'
$samples=[Domenia.Native.ProbeSamples]::new();$samples.AddUnique([object[]]@('A','a','B'),$now);$samples.AddUnique([object[]]@('A','B','B'),$now)
Expect ($samples.Machines -eq 2 -and $samples.Values.Count -eq 4 -and @($samples.Groups()|Where-Object Value -ne 2).Count -eq 0) 'multi-valued probes count each workstation once per category'
Expect ($samples.CountOther([string[]]@()) -eq 2 -and $samples.CountOther([string[]]@('A')) -eq 2) 'Other counts each workstation once even with several remaining values'
$samples=[Domenia.Native.ProbeSamples]::new();$samples.AddUnique([object[]]@(1.0,2.0,3.0),$now);$samples.AddUnique([object[]]@(2.0,3.0),$now)
Expect ($samples.CountRange(0,3) -eq 2 -and $samples.CountRange(0,1) -eq 1) 'multi-value histogram counts workstations, matching drilldown'
$identityReader=[Domenia.Native.ObservationIdentityReader]::new()
$identity=$identityReader.Read('{"Key":"dn","Guid":"g","UserGuid":"u","UserDn":"userdn","UserUsn":"12","LinkUser":"alice","Probes":{"bad":{"Rows":[["raw"]]}}}')
Expect ($identity.UserGuid -eq 'u' -and $identity.UserUsn -eq '12' -and $null -eq $identity.PSObject.Properties['Probes']) 'collection identity decoder skips complete probe graph'
. (Join-Path $modules 'Domenia-Park.Model.ps1')
$previous=[pscustomobject]@{Key='dn';Guid='g';RawAccount='D\alice';LinkUser='alice';UserDn='u';UserGuid='ug';UserUsn='12';ObservedUtc='2026-01-01T00:00:00Z';Inventory=[pscustomobject]@{Model='model'};Probes=[pscustomobject]@{x=[pscustomobject]@{Rows=@(,@('original'));CheckedUtc=$at}}}
$target=[pscustomobject]@{Key='dn';Guid='g';Previous=$null;PreviousJson=($previous|ConvertTo-Json -Depth 8 -Compress);DirectoryChanged=$true}
Expand-DomeniaParkPrevious $target
Expect ($target.Previous.DirectoryChanged -and $target.Previous.Probes.x.Rows[0][0] -eq 'original' -and -not $target.PreviousJson) 'lazy decoder preserves raw payload and directory change flag'
$result=[pscustomobject]@{Key='dn';Guid='g';Outcome='NoConsole';Computer='PC';Presence='En ligne';Detail=''}
$merged=ConvertTo-DomeniaParkSession $result $target.Previous
Expect (-not $merged.UserGuid -and -not $merged.LinkUser -and -not $merged.ObservedUtc -and $merged.Probes.x.Rows[0][0] -eq 'original') 'confirmed absence clears user identity but preserves unread measurements'
$result.Outcome='Unavailable';$merged=ConvertTo-DomeniaParkSession $result $target.Previous
Expect ($merged.UserGuid -eq 'ug' -and $merged.LinkUser -eq 'alice') 'failed reading preserves last confirmed identity'
Clear-DomeniaParkTargetBuffers @($target)
Expect ($null -eq $target.Previous -and -not $target.PreviousJson) 'completed target releases raw graph'
Write-Output ($script:checks.ToString()+' native assertions passed')
