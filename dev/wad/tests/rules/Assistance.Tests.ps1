# Point 110 : recettes d'assistance. Regles pures : contrat des recettes, etat des etapes, plan annonce.
. (Join-Path $modules 'Domenia-Assistance.Model.ps1')

Test-Case '110' 'Quatre recettes, chaque etape explique ce qu elle lit, pourquoi et a quel cout' {
    $recipes=@(Get-DomeniaAssistanceRecipes)
    Assert-Equal 'logon,slow,disk,software' (($recipes|ForEach-Object{$_.Id}) -join ',')
    Assert-Equal 0 @(Test-DomeniaAssistanceRecipes -Recipes $recipes).Count ((@(Test-DomeniaAssistanceRecipes -Recipes $recipes)) -join ' | ')
    foreach($recipe in $recipes){
        Assert-True ([string]$recipe.Symptom) $recipe.Id
        foreach($step in @($recipe.Steps)){
            foreach($field in @('Reads','Why','Cost')){Assert-True (([string]$step.$field).Length -gt 10) ($recipe.Id+'/'+$step.Id+' '+$field)}
            if([string]$step.Action){Assert-Equal 'Read' (Get-DomeniaOperationEffect ([string]$step.OperationId)) ($recipe.Id+'/'+$step.Id)}
        }
    }
    $logon=Get-DomeniaAssistanceRecipe 'logon'
    Assert-True (@($logon.Steps|Where-Object{$_.Subject -eq 'Utilisateur'}).Count -ge 2) 'Le compte est examine'
    Assert-True (@($logon.Steps|Where-Object{$_.Subject -eq 'Machine'}).Count -ge 2) 'Le poste est examine'
    Assert-Equal 'LockoutDiagnosis' (@($logon.Steps|Where-Object{$_.Id -eq 'lockouts'})[0].OperationId)
    Assert-True ($null -eq (Get-DomeniaAssistanceRecipe 'absente'))
}
Test-Case '110' 'Contrat des recettes : action non autorisee, ecriture, etape muette ou doublon refuses' {
    $write=[pscustomobject]@{Id='x';Title='X';Symptom='s';Steps=@([pscustomobject]@{Id='a';Title='Redemarrer';Subject='Machine';Action='Invoke-ComputerTool';OperationId='ComputerRestart';Workspace='';Reads='Rien de lu ici.';Why='Pour tester le refus.';Cost='Aucun cout ici.'})}
    $problems=@(Test-DomeniaAssistanceRecipes -Recipes @($write))
    Assert-True (($problems -join ' ') -match 'action non autorisée') ($problems -join ' | ')
    $forged=[pscustomobject]@{Id='y';Title='Y';Symptom='s';Steps=@([pscustomobject]@{Id='a';Title='T';Subject='Machine';Action='Start-ComputerDiagnostics';OperationId='ComputerRestart';Workspace='';Reads='Lecture forgee.';Why='Pour tester le refus.';Cost='Aucun cout ici.'})}
    $problems=@(Test-DomeniaAssistanceRecipes -Recipes @($forged))
    Assert-True (($problems -join ' ') -match 'opération incohérente') ($problems -join ' | ')
    Assert-True (($problems -join ' ') -match 'nʼest pas une lecture') ($problems -join ' | ')
    $mute=[pscustomobject]@{Id='z';Title='Z';Symptom='';Steps=@([pscustomobject]@{Id='a';Title='T';Subject='Machine';Action='';OperationId='';Workspace='';Reads='';Why='';Cost=''},[pscustomobject]@{Id='a';Title='T';Subject='Machine';Action='';OperationId='';Workspace='WsComputer';Reads='r';Why='w';Cost='c'})}
    $text=(@(Test-DomeniaAssistanceRecipes -Recipes @($mute,$mute)) -join ' | ')
    foreach($expected in @('symptôme absent','Reads absent','Why absent','Cost absent','ni lecture ni vue','étape sans identifiant unique','Recette sans identifiant unique')){Assert-True ($text -match [regex]::Escape($expected)) ('Absent : '+$expected+' / '+$text)}
}
Test-Case '110' 'Etat des etapes : sujet attendu, vue sans lecture, lancement date sans verdict' {
    $recipe=Get-DomeniaAssistanceRecipe 'logon'
    $rows=@(ConvertTo-DomeniaAssistanceStepRows -Recipe $recipe -SelectionType 'Utilisateur')
    Assert-Equal 6 $rows.Count;Assert-Equal 1 $rows[0].Order
    Assert-Equal 'Sans lecture : ouvrir la vue' $rows[0].State;Assert-False $rows[0].CanRun;Assert-True $rows[0].CanOpen
    Assert-Equal 'À lancer' $rows[1].State;Assert-True $rows[1].CanRun
    Assert-True ($rows[2].Title -match 'facultatif')
    Assert-Equal 'Sélectionnez le poste concerné.' $rows[3].State;Assert-False $rows[3].CanRun;Assert-False $rows[3].CanOpen
    Assert-Equal 'Poste' $rows[3].Pour
    $launched=@{lockouts=[datetime]::SpecifyKind([datetime]'2026-10-15T08:30:00',[DateTimeKind]::Utc)}
    $again=@(ConvertTo-DomeniaAssistanceStepRows -Recipe $recipe -SelectionType 'Utilisateur' -Launched $launched)
    Assert-True ($again[1].State -match '^Lancée à \d\d:\d\d : résultat dans sa vue$') $again[1].State
    Assert-False ($again[1].State -match '(?i)réussi|succès|OK') 'Un lancement ne vaut pas un resultat'
    Assert-Equal 'Sélectionnez le compte concerné.' (Get-DomeniaAssistanceStepState -Step $recipe.Steps[1] -SelectionType 'Machine').Text
    Assert-Equal 'Sélectionnez le compte concerné.' (Get-DomeniaAssistanceStepState -Step $recipe.Steps[1] -SelectionType '').Text
}
Test-Case '110' 'Plan annonce avant le premier clic : lectures par sujet, droits et etapes facultatives' {
    $text=Get-DomeniaAssistancePlanText (Get-DomeniaAssistanceRecipe 'logon')
    Assert-Equal '6 étape(s) : 2 lecture(s) pour le compte, 3 pour le poste, 1 sans lecture. 2 demande(nt) les droits dʼadministration du poste. 1 facultative(s). Aucune étape ne part seule ; aucune nʼécrit.' $text
    Assert-True ((Get-DomeniaAssistancePlanText (Get-DomeniaAssistanceRecipe 'disk')) -match '^3 étape\(s\) : 0 lecture\(s\) pour le compte, 3 pour le poste\.')
    $deep=@((Get-DomeniaAssistanceRecipe 'slow').Steps|Where-Object{$_.Id -eq 'deep'})[0]
    Assert-True $deep.Arguments['Deep'] 'Inventaire complet demande explicitement'
    Assert-Equal 'ComputerInventory' $deep.OperationId
}
