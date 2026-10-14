# Points 28 et 29 : schema AD en lecture seule et cout des filtres LDAP. Donnees fictives uniquement.
function New-DomeniaSchemaFixtureCatalog {
    $attributes=@(
        [pscustomobject]@{Name='cn';Description='Nom commun';Syntax='2.5.5.12';SingleValued=$true;SearchFlags=1;SystemFlags=16;InGlobalCatalog=$true;LinkId=$null;Defunct=$false}
        [pscustomobject]@{Name='sAMAccountName';Description='Identifiant';Syntax='2.5.5.12';SingleValued=$true;SearchFlags=13;SystemFlags=16;InGlobalCatalog=$true;LinkId=$null;Defunct=$false}
        [pscustomobject]@{Name='description';Description='Texte libre';Syntax='2.5.5.12';SingleValued=$false;SearchFlags=0;SystemFlags=16;InGlobalCatalog=$false;LinkId=$null;Defunct=$false}
        [pscustomobject]@{Name='objectCategory';Description='Categorie';Syntax='2.5.5.1';SingleValued=$true;SearchFlags=1;SystemFlags=16;InGlobalCatalog=$true;LinkId=$null;Defunct=$false}
        [pscustomobject]@{Name='userAccountControl';Description='Options';Syntax='2.5.5.9';SingleValued=$true;SearchFlags=0;SystemFlags=16;InGlobalCatalog=$true;LinkId=$null;Defunct=$false}
        [pscustomobject]@{Name='msDS-User-Account-Control-Computed';Description='Calcule';Syntax='2.5.5.9';SingleValued=$true;SearchFlags=0;SystemFlags=20;InGlobalCatalog=$false;LinkId=$null;Defunct=$false}
        [pscustomobject]@{Name='displayName';Description='Nom affiche';Syntax='2.5.5.12';SingleValued=$true;SearchFlags=33;SystemFlags=0;InGlobalCatalog=$true;LinkId=$null;Defunct=$false}
        [pscustomobject]@{Name='manager';Description='Responsable';Syntax='2.5.5.1';SingleValued=$true;SearchFlags=0;SystemFlags=16;InGlobalCatalog=$false;LinkId=42;Defunct=$false}
        [pscustomobject]@{Name='nom invalide';Description='';Syntax='2.5.5.12';SingleValued=$true;SearchFlags=0;SystemFlags=0;InGlobalCatalog=$false;LinkId=$null;Defunct=$false}
    )
    $classes=@(
        [pscustomobject]@{Name='top';Description='Racine';SubClassOf='top';Auxiliary=@();Must=@();May=@('cn','description');Category=2;Defunct=$false}
        [pscustomobject]@{Name='person';Description='Personne';SubClassOf='top';Auxiliary=@();Must=@('cn');May=@('description');Category=1;Defunct=$false}
        [pscustomobject]@{Name='organizationalPerson';Description='';SubClassOf='person';Auxiliary=@();Must=@();May=@('displayName','manager');Category=1;Defunct=$false}
        [pscustomobject]@{Name='user';Description='Compte';SubClassOf='organizationalPerson';Auxiliary=@('securityPrincipal');Must=@();May=@('sAMAccountName','userAccountControl','msDS-User-Account-Control-Computed','attributAbsent');Category=1;Defunct=$false}
        [pscustomobject]@{Name='securityPrincipal';Description='';SubClassOf='top';Auxiliary=@();Must=@('sAMAccountName');May=@();Category=3;Defunct=$false}
    )
    return (ConvertTo-DomeniaAdSchemaCatalog -Attributes $attributes -Classes $classes -Server 'dc1.example.invalid' -ObservedUtc '2026-10-14T08:00:00.0000000Z' -DomainDn 'DC=example,DC=invalid')
}
Test-Case 'P28' 'Schema : types, nombre de valeurs, index et heritage des classes' {
    $c=New-DomeniaSchemaFixtureCatalog
    Assert-Equal 8 $c.AttributeCount 'Un nom dʼattribut invalide est ecarte.';Assert-Equal 5 $c.ClassCount
    $sam=Get-DomeniaAdSchemaAttribute $c 'SAMACCOUNTNAME'
    Assert-True $sam.Indexed;Assert-True $sam.Anr;Assert-False $sam.TupleIndexed;Assert-Equal 'Texte Unicode' $sam.SyntaxLabel;Assert-Equal 'Text' $sam.Kind
    $computed=Get-DomeniaAdSchemaAttribute $c 'msDS-User-Account-Control-Computed';Assert-True $computed.Constructed
    Assert-Equal 'Calculé, non filtrable' (Get-DomeniaAdAttributeIndexText $computed)
    Assert-Equal 'Indexé, sous-chaîne comprise' (Get-DomeniaAdAttributeIndexText (Get-DomeniaAdSchemaAttribute $c 'displayName'))
    Assert-True (Get-DomeniaAdSchemaAttribute $c 'manager').Linked
    Assert-True ($null -eq (Get-DomeniaAdSchemaAttribute $null 'cn')) 'Sans schema lu, aucun attribut.'
    $u=Get-DomeniaAdClassAttributes -Catalog $c -ClassName 'user'
    Assert-True $u.Known
    $names=@($u.Rows|ForEach-Object{$_.Attribut})
    foreach($n in @('cn','description','displayName','manager','sAMAccountName','userAccountControl')){Assert-True ($names -contains $n) ('Attribut herite absent : '+$n)}
    Assert-Equal 'Oui' (@($u.Rows|Where-Object{$_.Attribut -eq 'sAMAccountName'})[0].Obligatoire) 'Obligatoire par la classe auxiliaire.'
    Assert-Equal 'Oui' @($u.Rows)[0].Obligatoire 'Les attributs obligatoires viennent en premier.'
    Assert-Equal 'user' @($u.Chain)[0];Assert-True (@($u.Chain) -contains 'securityPrincipal');Assert-Equal 1 @($u.Chain|Where-Object{$_ -eq 'top'}).Count 'top nʼest lu quʼune fois.'
    Assert-True (@($u.Missing) -contains 'attributAbsent') 'Un attribut absent du schema lu est signale.'
    Assert-False (Get-DomeniaAdClassAttributes -Catalog $c -ClassName 'inconnue').Known
    $found=Find-DomeniaAdSchemaEntries -Catalog $c -Text 'ACCOUNT' -Kind Attributes
    Assert-Equal 3 $found.Total
    $limited=Find-DomeniaAdSchemaEntries -Catalog $c -Text '' -Kind Attributes -Limit 2
    Assert-Equal 8 $limited.Total;Assert-Equal 2 $limited.Shown
    Assert-Equal 'Auxiliaire' (@((Find-DomeniaAdSchemaEntries -Catalog $c -Text 'securityPrincipal' -Kind Classes).Rows)[0].Nature)
    Assert-Equal 'Référence à un objet (DN)' (Get-DomeniaAdSyntaxLabel '2.5.5.1');Assert-Equal 'Syntaxe non reconnue' (Get-DomeniaAdSyntaxLabel '9.9')
    Assert-Equal 'LargeInt' (Get-DomeniaAdSyntaxKind '2.5.5.16')
}
Test-Case 'P28' 'Schema : exemple de critere et limites dites pour chaque attribut' {
    $c=New-DomeniaSchemaFixtureCatalog
    $h=Get-DomeniaAdAttributeQueryHint (Get-DomeniaAdSchemaAttribute $c 'description')
    Assert-Equal '(description=valeur*)' $h.Example
    Assert-True ((@($h.Notes) -join ' ') -match 'non indexé');Assert-True ((@($h.Notes) -join ' ') -match 'Plusieurs valeurs')
    $computed=Get-DomeniaAdAttributeQueryHint (Get-DomeniaAdSchemaAttribute $c 'msDS-User-Account-Control-Computed')
    Assert-Equal '' $computed.Example;Assert-True (@($computed.Notes)[0] -match 'calculé')
    Assert-False ((@((Get-DomeniaAdAttributeQueryHint (Get-DomeniaAdSchemaAttribute $c 'displayName')).Notes) -join ' ') -match 'joker en tête') 'Index de sous-chaine present.'
    Assert-True ((@((Get-DomeniaAdAttributeQueryHint (Get-DomeniaAdSchemaAttribute $c 'sAMAccountName')).Notes) -join ' ') -match 'joker en tête')
    $mgr=Get-DomeniaAdAttributeQueryHint (Get-DomeniaAdSchemaAttribute $c 'manager')
    Assert-True ($mgr.Example -match '^\(manager=CN=');Assert-True ((@($mgr.Notes) -join ' ') -match 'lié')
    Assert-Equal '(userAccountControl>=1)' (Get-DomeniaAdAttributeQueryHint (Get-DomeniaAdSchemaAttribute $c 'userAccountControl')).Example
    Assert-Equal 'Attribut inconnu du schéma lu.' @((Get-DomeniaAdAttributeQueryHint $null).Notes)[0]
}
Test-Case 'P29' 'Filtre LDAP : analyse syntaxique bornee, erreurs expliquees' {
    $ok=ConvertFrom-DomeniaLdapFilter '(&(objectCategory=computer)(|(name=PC-*)(description=*poste*))(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
    Assert-True $ok.Valid;Assert-Equal 'And' $ok.Root.Kind;Assert-Equal 3 @($ok.Root.Children).Count
    $ext=@(@($ok.Root.Children)[2].Children)[0]
    Assert-Equal 'Extensible' $ext.Kind;Assert-Equal 'userAccountControl' $ext.Attribute;Assert-Equal '1.2.840.113556.1.4.803' $ext.Rule
    $bare=ConvertFrom-DomeniaLdapFilter 'name=PC-01';Assert-True $bare.Valid;Assert-Equal 'Equality' $bare.Root.Kind
    Assert-Equal 'Presence' (ConvertFrom-DomeniaLdapFilter '(mail=*)').Root.Kind
    Assert-Equal 'GreaterOrEqual' (ConvertFrom-DomeniaLdapFilter '(whenChanged>=20260101000000.0Z)').Root.Kind
    Assert-True (ConvertFrom-DomeniaLdapFilter '(name=*abc)').Root.LeadingWildcard
    Assert-Equal 'cn' (ConvertFrom-DomeniaLdapFilter '(cn;lang-fr=x)').Root.Attribute 'Option dʼattribut retiree.'
    foreach($bad in @('','(&(name=a)','(name=a))','(!(a=b)(c=d))','(&)','((a=b))','(=x)','(a(b=c)','(1a=b)')){Assert-False (ConvertFrom-DomeniaLdapFilter $bad).Valid ('Filtre invalide accepte : '+$bad)}
    $deep=('(&'*70)+'(a=b)'+(')'*70)
    Assert-False (ConvertFrom-DomeniaLdapFilter $deep).Valid 'Profondeur bornee.'
    Assert-True ((ConvertFrom-DomeniaLdapFilter $deep).Error -match '64')
}
Test-Case 'P29' 'Filtre LDAP : cout selon les index du schema lu, inconnu sans schema' {
    $c=New-DomeniaSchemaFixtureCatalog
    $targeted=Get-DomeniaLdapFilterAnalysis '(&(objectCategory=computer)(description=*poste*))' $c
    Assert-Equal 'Ciblé' $targeted.Level;Assert-True (@($targeted.NotIndexed) -contains 'description');Assert-True (@($targeted.LeadingWildcards) -contains 'description')
    $broad=Get-DomeniaLdapFilterAnalysis '(description=*poste*)' $c
    Assert-Equal 'Large' $broad.Level;Assert-True ($broad.Text -match 'examine chaque objet')
    $neg=Get-DomeniaLdapFilterAnalysis '(!(cn=a))' $c;Assert-Equal 'Large' $neg.Level;Assert-Equal 1 $neg.Negations
    Assert-Equal 'Large' (Get-DomeniaLdapFilterAnalysis '(|(cn=a*)(description=b))' $c).Level 'Un OU nʼest cible que si chaque branche lʼest.'
    Assert-Equal 'Ciblé' (Get-DomeniaLdapFilterAnalysis '(|(cn=a*)(sAMAccountName=b))' $c).Level
    Assert-Equal 'Ciblé' (Get-DomeniaLdapFilterAnalysis '(displayName=*dupont*)' $c).Level 'Index de sous-chaine.'
    Assert-Equal 'Ciblé' (Get-DomeniaLdapFilterAnalysis '(sAMAccountName=jdu*)' $c).Level
    Assert-Equal 'Large' (Get-DomeniaLdapFilterAnalysis '(sAMAccountName=*dupont)' $c).Level
    Assert-Equal 'Large' (Get-DomeniaLdapFilterAnalysis '(userAccountControl:1.2.840.113556.1.4.803:=2)' $c).Level
    $computed=Get-DomeniaLdapFilterAnalysis '(&(objectCategory=person)(msDS-User-Account-Control-Computed=16))' $c
    Assert-True (@($computed.Constructed) -contains 'msDS-User-Account-Control-Computed');Assert-True ($computed.Text -match 'calculé')
    Assert-Equal 'Ciblé' (Get-DomeniaLdapFilterAnalysis '(&(objectCategory=person)(inconnu=1))' $c).Level 'Un critere indexe suffit a cibler un ET.'
    $unknownOnly=Get-DomeniaLdapFilterAnalysis '(inconnu=1)' $c
    Assert-Equal 'Inconnu' $unknownOnly.Level;Assert-True (@($unknownOnly.Unknown) -contains 'inconnu');Assert-True ($unknownOnly.Text -match 'absent')
    $noSchema=Get-DomeniaLdapFilterAnalysis '(sAMAccountName=jdupont)' $null
    Assert-Equal 'Inconnu' $noSchema.Level;Assert-True ($noSchema.Text -match 'Index non vérifiés')
    Assert-Equal 'Ciblé' (Get-DomeniaLdapFilterAnalysis '(anr=dupont)' $null).Level 'Resolution ambigue des noms.'
    $invalid=Get-DomeniaLdapFilterAnalysis '(&(a=b)' $c
    Assert-False $invalid.Valid;Assert-Equal 'Invalide' $invalid.Level
}
Test-Case 'P29' 'Saisie au clavier et joker en tete : jamais de recherche large implicite' {
    Assert-False (Test-DomeniaTypedSearchAllowed '*' 2).Allowed
    Assert-False (Test-DomeniaTypedSearchAllowed '*pont' 2).Allowed
    Assert-False (Test-DomeniaTypedSearchAllowed 'ab' 2).Allowed 'Trois caracteres au moins pour une recherche automatique.'
    Assert-False (Test-DomeniaTypedSearchAllowed 'a* *' 2).Allowed
    Assert-False (Test-DomeniaTypedSearchAllowed '' 2).Allowed
    Assert-True (Test-DomeniaTypedSearchAllowed 'dup' 2).Allowed
    Assert-False (Test-DomeniaTypedSearchAllowed 'dupo' 5).Allowed
    $type='(objectClass=user)'
    $plan=Get-DomeniaGlobalSearchPlan '*dupont' $type 2 $true
    Assert-Equal 'Default' $plan.Kind;Assert-True ($plan.Hint -match 'Joker en tête')
    Assert-False ((Get-DomeniaGlobalSearchPlan 'dupont*' $type 2 $true).Hint -match 'Joker') 'Un joker final utilise lʼindex.'
}
