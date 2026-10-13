$out='C:\Users\degun\domenia-lab\vmstage\profile-exposure-tree';[void][IO.Directory]::CreateDirectory($out)
$started=[datetime]::UtcNow.ToString('o')
& $vb guestcontrol 'CNAMTS-W11-01' copyfrom @auth --recursive 'C:\DomeniaLab\query-navigation-20261013-r5\captures' ($out+'\')
[pscustomobject]@{Kind='GuestControlSameUserCopyFromTree';StartUtc=$started;EndUtc=[datetime]::UtcNow.ToString('o');ExitCode=$LASTEXITCODE}|ConvertTo-Json
