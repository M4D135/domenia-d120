# Coffre de la fenetre de connexion (decision David 2026-10-19) : le compte memorise est reconnu avec ou sans sa
# partie domaine, et la raison d'un bouton indisponible est dite. Regles pures, aucun coffre Windows lu.
. (Join-Path $modules 'Domenia-CredentialVault.Model.ps1')
Test-Case 'VAULT-001' 'Le compte memorise est reconnu avec ou sans domaine, sans tenir compte de la casse' {
    $key = ConvertTo-DomeniaVaultLoginKey 'admpmf-111301-10656'
    foreach ($typed in @('CNAMTS\admpmf-111301-10656','admpmf-111301-10656@cnamts.local','  ADMPMF-111301-10656 ')) { Assert-Equal $key (ConvertTo-DomeniaVaultLoginKey $typed) $typed }
    Assert-False ((ConvertTo-DomeniaVaultLoginKey 'CNAMTS\autre') -ceq $key) 'autre compte reconnu'
    Assert-Equal '' (ConvertTo-DomeniaVaultLoginKey '')
}
Test-Case 'VAULT-002' 'La raison d un coffre indisponible est dite' {
    Assert-True ((Get-DomeniaVaultLoginReason -Typed 'x' -Account '' -DomainDn '') -like 'Aucun compte mémorisé*Mémoriser sur ce PC*') 'aucun compte'
    Assert-True ((Get-DomeniaVaultLoginReason -Typed 'autre' -Account 'CNAMTS\admpmf' -DomainDn 'DC=cnamts,DC=local') -like '*pour CNAMTS\admpmf*saisissez ce compte*') 'autre compte saisi'
    Assert-True ((Get-DomeniaVaultLoginReason -Typed 'admpmf' -Account 'CNAMTS\admpmf' -DomainDn 'DC=cnamts,DC=local') -like '*autre domaine*') 'meme compte, domaine different'
    Assert-True ((Get-DomeniaVaultLoginReason -Demo $true) -like '*démonstration*') 'demonstration'
}
