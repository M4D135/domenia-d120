$ErrorActionPreference='Stop';$root='C:\DomeniaLab\RC35-qualification';$out=Join-Path $root 'startup38-final';$passed=$false;$errorText='';[void][IO.Directory]::CreateDirectory($out)
[datetime]::UtcNow.ToString('o')|Set-Content (Join-Path $out 'ComparisonStarted.txt')
function Set-Runtime($version){
 foreach($name in @('Domenia-Core.ps1','Domenia-Main.xaml','Domenia-Modules.ps1','Domenia.release.json','package-manifest.json')){Copy-Item (Join-Path $root ($version+'\prod\wad\'+$name)) (Join-Path $root ('startup38\prod\wad\'+$name)) -Force}
}
try{
 foreach($label in @('AfterIdle1','BeforeIdle1','BeforeIdle2','AfterIdle2')){
  if($label.StartsWith('Before')){Set-Runtime 'RC37'}else{Set-Runtime 'RC38'}
  $p=Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Measure-Final.ps1')+'" -Label '+$label+$(if($label -eq 'AfterIdle2'){' -KeepOpen'}else{''})) -PassThru
  if(-not $p.WaitForExit(900000)){throw ('Measure timeout: '+$label)}
  $r=Get-Content (Join-Path $out ($label+'.json')) -Raw|ConvertFrom-Json
  if(-not $r.Passed){throw ('Measure failed: '+$label+' '+$r.Error)}
 }
 $passed=$true
}catch{$errorText=$_.Exception.Message}
finally{Set-Runtime 'RC38'; & 'C:\Windows\System32\VBoxControl.exe' guestproperty set '/Domenia/RC38/Qualification' 'Complete'}
[pscustomobject]@{Passed=$passed;Error=$errorText;Utc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $out 'Comparison.json')
