using Domenia.Core;

namespace Domenia.Tests;

internal static class DistinguishedNameTests
{
    [Test]
    public static void Display_decoding_keeps_invalid_octets_visible_without_changing_the_data_parser()
    {
        const string dn = @"CN=Ren\FF,OU=Par\E9,DC=example,DC=local";
        Check.Equal(@"Ren\xFF", FicheValues.DisplayName(dn), "octet invalide du nom visible");
        Check.Contains(@"Par\xE9", FicheValues.ReadablePath(dn), "octet invalide du chemin visible");
        Check.Equal(@"Par\xE9", DistinguishedName.SiteOf(dn), "l’OU affichée conserve chaque octet invalide");
        Check.Equal("Ren\uFFFD", DistinguishedName.Parse(dn)[0].Value, "le parseur des données et des périmètres garde son contrat");
        Check.Equal(@"OU=Par\E9,DC=example,DC=local", DistinguishedName.Parent(dn), "le parent brut n’est jamais réécrit");
    }

    [Test]
    public static void Escapes_inside_quoted_values_are_consumed_once_and_keep_the_same_scope()
    {
        const string quoted = "CN=\"Le Gall\\, Ren\\C3\\A9\\\\fin\",OU=Postes,DC=example,DC=local";
        const string escaped = @"CN=Le Gall\, Ren\C3\A9\\fin,OU=Postes,DC=example,DC=local";
        Check.Equal("Le Gall, René\\fin", DistinguishedName.Parse(quoted)[0].Value, "chaque échappement est consommé une seule fois");
        Check.True(DistinguishedName.AreEqual(quoted, escaped), "le nom cité et le nom échappé désignent le même objet");
        Check.Equal("OU=Postes,DC=example,DC=local", DistinguishedName.Parent(quoted), "parent brut inchangé");
        Check.True(DistinguishedName.IsWithin(quoted, "OU=Postes,DC=example,DC=local", false), "le périmètre reste structurel");
        Check.False(DistinguishedName.IsWithin(quoted, "OU=Autres,DC=example,DC=local", true), "aucun périmètre voisin accepté");
    }

    [Test]
    public static void AdsPath_writes_the_slash_of_a_value_escaped_and_never_twice()
    {
        const string escaped = @"OU=Est\/Ouest,DC=example,DC=local";
        Check.Equal(escaped, DistinguishedName.AdsPathDn("OU=Est/Ouest,DC=example,DC=local"), "un « / » de valeur RDN est écrit « \\/ »");
        Check.Equal(escaped, DistinguishedName.AdsPathDn(escaped), "un DN déjà écrit « \\/ » ne reçoit pas un second échappement");
        Check.Equal(escaped, DistinguishedName.AdsPathDn(DistinguishedName.AdsPathDn(escaped)), "écrire deux fois ne change rien");
        Check.Equal(@"CN=Le Gall\, Anne,OU=Est\/Ouest", DistinguishedName.AdsPathDn(@"CN=Le Gall\, Anne,OU=Est/Ouest"), "les échappements RFC 4514 survivent à l’écriture du chemin");
        Check.Equal(@"a\\b\/c", DistinguishedName.EscapeAdsPathValue(@"a\b/c"), "un antislash brut reste échappé, le « / » l’est une fois");
        Check.Equal(@"Est\/ Ouest", DistinguishedName.EscapeAdsPathValue("Est/ Ouest"), "un « / » de la valeur est échappé, les blancs du milieu restent");
        var read = DistinguishedName.Parse(escaped);
        Check.Equal("Est/Ouest", read[0].Value, "la valeur relue retrouve son « / »");
        Check.Equal("OU", read[0].Type, "le type du RDN est gardé tel qu’écrit");
    }

    [Test]
    public static void AdsPath_addresses_the_server_and_refuses_a_server_that_is_already_a_path()
    {
        Check.Equal(@"LDAP://dc01.example.local/OU=Est\/Ouest,DC=example,DC=local",
            DistinguishedName.AdsPath("dc01.example.local", "OU=Est/Ouest,DC=example,DC=local"), "LDAP://serveur/DN avec le « / » échappé");
        Check.Equal("LDAP://dc01.example.local", DistinguishedName.AdsPath(" dc01.example.local ", ""), "un DN vide adresse le serveur lui-même");
        Check.Throws<FormatException>(() => DistinguishedName.AdsPath("LDAP://dc01", "DC=example,DC=local"), "un serveur déjà écrit en URL est refusé, jamais concaténé");
        Check.Throws<FormatException>(() => DistinguishedName.AdsPath("dc 01", "DC=example,DC=local"), "un serveur avec un blanc est refusé");
        Check.Throws<FormatException>(() => DistinguishedName.AdsPath("dc01/x", "DC=example,DC=local"), "un serveur avec un séparateur est refusé");
        Check.Throws<FormatException>(() => DistinguishedName.AdsPathDn("sans signe égal"), "un DN illisible n’est pas rendu tel quel : rien n’est inventé");
    }

    [Test]
    public static void GpLink_adspath_of_a_container_with_a_slash_is_read_back_as_the_same_dn()
    {
        const string gpLink = @"[LDAP://cn={7C9E4B4E-2D87-4C4E-9B4E-3E6A0D7A1B23},cn=policies,cn=system,OU=Est\/Ouest,DC=example,DC=local;0]";
        var link = AuditGpoRules.ParseGpLink(gpLink, @"OU=Est\/Ouest,DC=example,DC=local").Single();
        Check.Equal(Guid.Parse("7C9E4B4E-2D87-4C4E-9B4E-3E6A0D7A1B23"), link.Guid, "GPO identifiée malgré le « / » échappé du conteneur");
        Check.True(link.LinkEnabled, "option nulle : lien activé");
        Check.False(link.Enforced, "option nulle : lien non forcing");
        Check.Equal("Est/Ouest", DistinguishedName.Parse(link.ContainerDn)[0].Value, "le conteneur reloué retrouve son « / »");
    }

    [Test]
    public static void Site_of_a_dn_names_the_site_or_the_ou_of_membership_and_nothing_else()
    {
        Check.Equal("Postes", DistinguishedName.SiteOf("OU=Postes,OU=Paris,DC=example,DC=local"), "l’OU d’appartenance est la plus proche de l’objet");
        Check.Equal("Domain Controllers", DistinguishedName.SiteOf("CN=SRV-01,OU=Domain Controllers,DC=example,DC=local"), "l’OU de contrôleurs est nommée comme appartenance");
        Check.Equal("Default-First-Site-Name", DistinguishedName.SiteOf("CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=example,DC=local"), "le site est lu au-dessus de CN=Sites de la configuration");
        Check.Null(DistinguishedName.SiteOf("CN=Sites,CN=Configuration,DC=example,DC=local"), "aucun nom au-dessus de CN=Sites : rien n’est appelé site");
        Check.Null(DistinguishedName.SiteOf("DC=example,DC=local"), "le domaine n’est ni un site ni une OU");
        Check.Null(DistinguishedName.SiteOf("CN=PC-01,CN=Computers,DC=example,DC=local"), "un conteneur par défaut sans OU n’est pas donné pour une OU d’appartenance");
        Check.Equal("Le Gall, Anne", DistinguishedName.SiteOf(@"OU=Le Gall\, Anne,DC=example,DC=local"), "une virgule échappée est décodée dans le nom rendu");
        Check.Throws<FormatException>(() => DistinguishedName.SiteOf("sans signe égal"), "un DN illisible n’est pas deviné");
    }

    [Test]
    public static void Quoted_rfc_4514_values_are_read_and_their_internal_comma_is_not_a_separator()
    {
        static string FirstValue(string dn, int expectedParts)
        {
            var parsed = DistinguishedName.Parse(dn);
            Check.Equal(expectedParts, parsed.Length, "tous les segments du DN sont conservés");
            return parsed[0].Value;
        }
        var names = DistinguishedName.Parse("CN=\"Le Gall, Anne\",OU=Postes,DC=example,DC=local");
        Check.Equal(4, names.Length, "quatre noms relatifs lus : la virgule entre guillemets n’a pas séparé");
        Check.Equal("CN", names[0].Type, "le type est lu avant la valeur entre guillemets");
        Check.Equal("Le Gall, Anne", names[0].Value, "la valeur entre guillemets est décodée sans ses guillemets");
        Check.Equal("Postes", names[1].Value, "l’OU qui suit la valeur entre guillemets est lue");
        Check.Equal(@"CN=Le Gall\, Anne,OU=Postes,DC=example,DC=local", DistinguishedName.Format(names), "la valeur relue s’écrit avec une virgule échappée");
        Check.Equal("OU=Postes,DC=example,DC=local", DistinguishedName.Parent("CN=\"Le Gall, Anne\",OU=Postes,DC=example,DC=local"), "le parent saute la virgule portée par les guillemets");
        Check.Equal("Anne\"Quote", FirstValue(@"CN=""Anne\""Quote"",OU=Postes,DC=example,DC=local", 4), "un guillemet échappé dans la valeur entre guillemets est décodé");
        Check.Equal("A b", FirstValue(@"OU=""\41 b"",DC=example,DC=local", 3), "une paire hexadécimale lue entre guillemets décode son octet");
        Check.Equal("  Paris  ", FirstValue("OU=\"  Paris  \",DC=example,DC=local", 3), "les blancs portés par les guillemets appartiennent à la valeur");
        Check.Equal("a\"b", FirstValue("CN=a\\\"b,DC=example,DC=local", 3), "un guillemet échappé hors guillemets est lu comme avant");
        Check.Equal("DC=example,DC=local", DistinguishedName.Parent(@"OU=a""b,DC=example,DC=local"), "un guillemet en plein milieu de valeur ne change pas la découpe");
        Check.Throws<FormatException>(() => DistinguishedName.Parse("CN=\"sans fermeture,OU=Postes,DC=example,DC=local"), "une valeur entre guillemets non fermée est refusée");
        Check.Throws<FormatException>(() => DistinguishedName.Parse("CN=\"a\"b,DC=example,DC=local"), "du texte après le guillemet fermant est refusé, rien n’est deviné");
    }
}
