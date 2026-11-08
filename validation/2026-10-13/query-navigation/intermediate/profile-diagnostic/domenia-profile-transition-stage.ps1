& $vb guestcontrol 'CNAMTS-W11-01' copyto @auth 'C:\Users\degun\domenia-lab\vmstage\domenia-profile-transition.ps1' 'C:\DomeniaLab\query-navigation-20261013-r5\profile-transition.ps1'
if($LASTEXITCODE){throw 'transfer failed'}
& $vb guestcontrol 'CNAMTS-W11-01' start @auth --exe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -- powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\DomeniaLab\query-navigation-20261013-r5\profile-transition.ps1' -Case transition -WaitSeconds 3
