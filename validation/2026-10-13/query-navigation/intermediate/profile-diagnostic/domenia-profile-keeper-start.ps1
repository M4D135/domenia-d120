$started=[datetime]::UtcNow.ToString('o')
& $vb guestcontrol 'CNAMTS-W11-01' start @auth --profile --exe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -- powershell.exe -NoProfile -NonInteractive -Command 'Start-Sleep -Seconds 8'
[pscustomobject]@{Kind='GuestControlProfileKeeper';StartUtc=$started;StartedUtc=[datetime]::UtcNow.ToString('o');GuestProcess='PowerShell Start-Sleep 8s';Profile=$true;ExitCode=$LASTEXITCODE}|ConvertTo-Json
