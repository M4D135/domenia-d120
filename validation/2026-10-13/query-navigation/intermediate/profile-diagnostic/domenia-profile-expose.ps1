$started=[datetime]::UtcNow.ToString('o')
& $vb guestcontrol 'CNAMTS-W11-01' copyfrom @auth 'C:\DomeniaLab\query-navigation-20261013-r5\proof\package.json' 'C:\Users\degun\domenia-lab\vmstage\profile-exposure-package.json'
[pscustomobject]@{Kind='GuestControlSameUserCopyFrom';StartUtc=$started;EndUtc=[datetime]::UtcNow.ToString('o');ExitCode=$LASTEXITCODE}|ConvertTo-Json
