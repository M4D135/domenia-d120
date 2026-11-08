$root='C:\DomeniaLab\query-navigation-20261013-r6'
& $vb guestcontrol 'CNAMTS-W11-01' mkdir @auth --parents $root
foreach($pair in @(@('domenia-navigation-r5-dev.zip','dev.zip'),@('domenia-navigation-r6-run.ps1','run.ps1'),@('domenia-navigation-r5-capture.ps1','capture-guides.ps1'),@('domenia-navigation-r5-prod.zip','prod.zip'),@('domenia-navigation-r6-prod-check.ps1','prod-check.ps1'))){
 & $vb guestcontrol 'CNAMTS-W11-01' copyto @auth ('C:\Users\degun\domenia-lab\vmstage\'+$pair[0]) ($root+'\'+$pair[1])
 if($LASTEXITCODE){throw ('Copy failed: '+$pair[0])}
}
& $vb guestcontrol 'CNAMTS-W11-01' start @auth --exe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -- powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File ($root+'\run.ps1') -ExpectedZip 'fffc258b7715eac4d57d19817336262ff827ce455d90aea0e32a7cc35653dd44' -ExpectedCapture '1f8ac7b4902a975c7c322396ccf912188c0480c0d439ed403ee5ce9ea34ca2f0'
if($LASTEXITCODE){throw 'Guest process start failed'}
