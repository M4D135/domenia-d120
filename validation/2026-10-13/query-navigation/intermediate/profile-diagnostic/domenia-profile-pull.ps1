$out='C:\Users\degun\domenia-lab\vmstage\profile-diagnostic';[void][IO.Directory]::CreateDirectory($out)
& $vb guestcontrol 'CNAMTS-W11-01' copyfrom @auth --recursive 'C:\DomeniaLab\query-navigation-20261013-r5\profile-diagnostic' ($out+'\')
