using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Local analysis of an LDAP filter (Domenia 1 point 29, docs/ops/schema.md § 7 and 8). Written now, run at the end.</summary>
internal static class LdapFilterTests
{
    private const string Nbsp = " ";

    /// <summary>Small schema: cn indexed, description not, displayName with substring index, a constructed and a confidential one.</summary>
    private static SchemaCatalog Catalog()
    {
        SchemaAttributeDefinition A(string name, string syntax, long search, long system = 0, bool single = true) =>
            new(name, null, null, syntax, null, single, search, system, false, null, null, null, false);
        var read = new SchemaReadResult(
            [
                A("cn", "2.5.5.12", 1), A("description", "2.5.5.12", 0, single: false), A("displayName", "2.5.5.12", 1 | 32),
                A("objectClass", "2.5.5.2", 1, single: false), A("objectCategory", "2.5.5.1", 1), A("userAccountControl", "2.5.5.9", 1),
                A("createTimeStamp", "2.5.5.11", 0, 4), A("whenCreated", "2.5.5.11", 0), A("ms-Mcs-AdmPwd", "2.5.5.12", 128 | 8),
                A("sAMAccountName", "2.5.5.12", 1 | 4 | 8), A("pwdLastSet", "2.5.5.16", 0),
            ],
            [
                new SchemaClassDefinition("person", null, null, "top", [], ["cn"], [], 0, false),
                new SchemaClassDefinition("organizationalPerson", null, null, "person", [], [], [], 0, false),
                new SchemaClassDefinition("user", null, null, "organizationalPerson", [], [], ["cn"], 1, false),
                new SchemaClassDefinition("computer", null, null, "user", [], [], [], 1, false),
                new SchemaClassDefinition("contact", null, null, "organizationalPerson", [], [], [], 1, false),
            ],
            "DC1.test.local", TestClock.Reference, false, 12, "DC=test,DC=local", "CN=Schema,CN=Configuration,DC=test,DC=local");
        return SchemaRules.BuildCatalog(read);
    }

    private static string? Error(string filter) => LdapFilter.Parse(filter).Error;

    [Test]
    public static void Syntax_errors_keep_the_words_and_positions_of_Domenia_1()
    {
        Check.Equal("Filtre vide.", Error("   "), "vide");
        Check.Equal("Parenthèse fermante manquante.", Error("(cn=a"), "parenthèse manquante");
        Check.Equal("Un ET (&) ou un OU (|) sans filtre est vide.", Error("(&)"), "ET vide");
        Check.Equal("Une négation (!) porte sur un seul filtre.", Error("(!(a=b)(c=d))"), "négation double");
        Check.Equal("Assertion sans opérateur" + Nbsp + ": «" + Nbsp + "x" + Nbsp + "».", Error("(x)"), "sans opérateur");
        Check.Equal("Nom d’attribut invalide" + Nbsp + ": «" + Nbsp + "1a" + Nbsp + "».", Error("(1a=b)"), "nom invalide");
        Check.Equal("Texte inattendu après le filtre, position 6.", Error("(a=b))"), "texte en trop");
        Check.Contains("écrivez \\28 et \\29", Error("(a=(b)"), "parenthèse non échappée");
        Check.Equal("Parenthèse fermante attendue, position 3.", Error("(&a=b)"), "fermante attendue après l’opérateur, comme Domenia 1");
        var deep = string.Concat(Enumerable.Repeat("(&", 66)) + "(a=b)" + new string(')', 66);
        Check.Equal("Filtre trop imbriqué" + Nbsp + ": 64 niveaux au plus.", Error(deep), "64 niveaux");
        var wide = "(|" + string.Concat(Enumerable.Repeat("(a=b)", 2000)) + ")";
        Check.Equal("Filtre trop long" + Nbsp + ": 2 000 éléments au plus.", Error(wide), "2 000 éléments");
        Check.Equal("Filtre trop long" + Nbsp + ": 32 768 caractères au plus.", Error("(cn=" + new string('a', 32800) + ")"), "32 768 caractères");
        var at = LdapFilter.Parse("(a=b))");
        Check.Equal(5, at.ErrorPosition, "position de l’erreur dans le texte normalisé");
    }

    [Test]
    public static void Assertions_are_classified()
    {
        LdapFilterNode Root(string f) => LdapFilter.Parse(f).Root!;
        Check.Equal(LdapFilterNodeKind.Presence, Root("(cn=*)").Kind, "présence");
        Check.Equal(LdapFilterNodeKind.Substring, Root("(cn=a*)").Kind, "sous-chaîne");
        Check.False(Root("(cn=a*)").LeadingWildcard, "début de valeur");
        Check.True(Root("(cn=*a)").LeadingWildcard, "joker en tête");
        Check.Equal(LdapFilterNodeKind.GreaterOrEqual, Root("(x>=1)").Kind, "supérieur ou égal");
        Check.Equal(LdapFilterNodeKind.LessOrEqual, Root("(x<=1)").Kind, "inférieur ou égal");
        Check.Equal(LdapFilterNodeKind.Approx, Root("(x~=a)").Kind, "approché");
        var extensible = Root("(userAccountControl:1.2.840.113556.1.4.803:=2)");
        Check.Equal(LdapFilterNodeKind.Extensible, extensible.Kind, "règle de correspondance");
        Check.Equal("userAccountControl", extensible.Attribute, "attribut de la règle");
        Check.Equal("1.2.840.113556.1.4.803", extensible.Rule, "règle");
        Check.Equal("", Root("(cn:dn:=x)").Rule, "« dn » n’est pas une règle");
        Check.Equal("cn", Root("(cn;lang-fr=x)").Attribute, "option d’attribut retirée");
        var bare = LdapFilter.Parse("cn=a");
        Check.True(bare.Valid, "filtre sans parenthèses extérieures complété");
        Check.Equal("(cn=a)", bare.Text, "texte normalisé");
    }

    [Test]
    public static void Index_use_follows_the_schema_read()
    {
        var catalog = Catalog();
        LdapIndexUse Use(string f, SchemaCatalog? c = null) => LdapFilter.IndexUse(LdapFilter.Parse(f).Root!, c ?? catalog);
        Check.Equal(LdapIndexUse.Yes, Use("(cn=Dupont)"), "égalité indexée");
        Check.Equal(LdapIndexUse.Yes, Use("(cn=Dup*)"), "début de valeur indexé");
        Check.Equal(LdapIndexUse.No, Use("(cn=*pont)"), "joker en tête sans index de sous-chaîne");
        Check.Equal(LdapIndexUse.Yes, Use("(displayName=*pont)"), "joker en tête avec index de sous-chaîne");
        Check.Equal(LdapIndexUse.No, Use("(description=x)"), "non indexé");
        Check.Equal(LdapIndexUse.Yes, Use("(&(description=x)(cn=y))"), "ET avec un critère indexé");
        Check.Equal(LdapIndexUse.No, Use("(|(description=x)(cn=y))"), "OU avec une branche non indexée");
        Check.Equal(LdapIndexUse.No, Use("(!(cn=y))"), "négation");
        Check.Equal(LdapIndexUse.Yes, Use("(anr=martin)"), "ANR");
        Check.Equal(LdapIndexUse.No, Use("(objectClass=*)"), "présence de objectClass : tout le périmètre");
        Check.Equal(LdapIndexUse.No, Use("(createTimeStamp>=20260101000000.0Z)"), "calculé");
        Check.Equal(LdapIndexUse.Unknown, Use("(licorne=1)"), "absent du schéma");
        Check.Equal(LdapIndexUse.No, Use("(userAccountControl:1.2.840.113556.1.4.803:=2)"), "règle de correspondance");
        Check.Equal(LdapIndexUse.Unknown, LdapFilter.IndexUse(LdapFilter.Parse("(cn=x)").Root!, null), "schéma non lu");
    }

    [Test]
    public static void Analysis_gives_the_level_and_the_advice()
    {
        var catalog = Catalog();
        var targeted = LdapFilter.Analyze("(&(objectCategory=person)(cn=Dup*))", catalog);
        Check.Equal(LdapFilterLevel.Targeted, targeted.Level, "ciblé");
        Check.Equal("Ciblé", targeted.LevelLabel, "libellé");
        Check.True(targeted.Text.StartsWith("Coût LDAP" + Nbsp + ": Ciblé. Filtre ciblé", StringComparison.Ordinal), "texte de Domenia 1 : " + targeted.Text);
        Check.NotNull(targeted.Tree, "structure du filtre");
        Check.Equal(2, targeted.Tree!.Children.Length, "deux critères");

        var broad = LdapFilter.Analyze("(&(description=*stagiaire*)(!(cn=a))(ms-Mcs-AdmPwd=*)(createTimeStamp>=1)(userAccountControl:1.2.840.113556.1.4.803:=2))", catalog);
        Check.Equal(LdapFilterLevel.Broad, broad.Level, "large");
        Check.Equal(Tone.Warn, broad.Tone, "ton");
        Check.True(broad.LeadingWildcards.SequenceEqual(["description"]), "joker en tête");
        Check.Equal(1, broad.Negations, "négation");
        Check.Equal(1, broad.Extensible, "règle");
        Check.True(broad.Constructed.SequenceEqual(["createTimeStamp"]), "calculé");
        Check.True(broad.Confidential.SequenceEqual(["ms-Mcs-AdmPwd"]), "confidentiel");
        Check.True(broad.Advice.Any(a => a.StartsWith("Filtre large", StringComparison.Ordinal)), "conseil large");
        Check.True(broad.Advice.Any(a => a.StartsWith("La négation (!) n’utilise aucun index", StringComparison.Ordinal)), "conseil négation");

        var unknown = LdapFilter.Analyze("(licorne=1)", catalog);
        Check.Equal(LdapFilterLevel.Unknown, unknown.Level, "inconnu");
        Check.Equal("Coût indéterminé" + Nbsp + ": licorne est absent du schéma lu.", unknown.Advice[0], "attribut absent nommé");

        var noSchema = LdapFilter.Analyze("(cn=x)", null);
        Check.False(noSchema.SchemaUsed, "sans schéma");
        Check.Contains("Index non vérifiés", noSchema.Advice[0], "invite à lire le schéma");

        var invalid = LdapFilter.Analyze("(cn=a", catalog);
        Check.False(invalid.Valid, "invalide");
        Check.Equal(LdapFilterLevel.Invalid, invalid.Level, "niveau invalide");
        Check.Equal("Filtre non valide" + Nbsp + ": Parenthèse fermante manquante.", invalid.Text, "texte d’erreur");
    }

    [Test]
    public static void Suggestions_rewrite_only_what_is_safe()
    {
        var catalog = Catalog();
        var user = LdapFilter.Analyze("(objectClass=user)", catalog);
        Check.Equal("(&(objectCategory=person)(objectClass=user))", user.Suggestion?.Filter, "objectCategory ajouté");
        var inAnd = LdapFilter.Analyze("(&(objectClass=user)(description=x))", catalog);
        Check.Equal("(&(objectCategory=person)(objectClass=user)(description=x))", inAnd.Suggestion?.Filter, "dans le ET");
        var created = LdapFilter.Analyze("(createTimeStamp>=20260101000000.0Z)", catalog);
        Check.Equal("(whenCreated>=20260101000000.0Z)", created.Suggestion?.Filter, "équivalent stocké exact");
        var leading = LdapFilter.Analyze("(cn=*pont*)", catalog);
        Check.Equal("(cn=pont*)", leading.Suggestion?.Filter, "joker en tête retiré sur un attribut indexé");
        var negation = LdapFilter.Analyze("(!(description=*))", catalog);
        Check.Null(negation.Suggestion?.Filter, "négation : conseil seulement");
        Check.True(negation.Suggestion!.Reasons.Any(r => r.Contains("négation", StringComparison.Ordinal)), "raison donnée");
        Check.Null(LdapFilter.Analyze("(cn=Dupont)", catalog).Suggestion, "rien à proposer");
    }

    [Test]
    public static void Category_rewriting_names_what_it_leaves_out()
    {
        var catalog = Catalog();
        // objectCategory=person leaves out computer, which derives from user with another category: the reason says so.
        var user = LdapFilter.Analyze("(objectClass=user)", catalog).Suggestion!;
        Check.Contains("écarte computer, qui dérive de user avec une autre catégorie", user.Reasons[0], "raison de user");
        var person = LdapFilter.Analyze("(objectClass=person)", catalog).Suggestion!;
        Check.Equal("(&(objectCategory=person)(objectClass=person))", person.Filter, "réécriture proposée");
        Check.Contains("écarte computer", person.Reasons[0], "person : le sens change, et c’est dit");
        Check.False(person.Reasons[0].Contains("limite les objets examinés", StringComparison.Ordinal), "jamais présenté comme un simple gain d’index");
        // contact: every object of the class has the category person, objectClass is indexed: nothing to propose.
        Check.Null(LdapFilter.Analyze("(objectClass=contact)", catalog).Suggestion, "contact : rien à proposer");
        Check.True(SchemaRules.CategoryExclusions("contact", catalog).IsEmpty, "contact : aucune classe écartée");
        Check.True(SchemaRules.CategoryExclusions("organizationalPerson", catalog).SequenceEqual(["computer"]), "organizationalPerson : computer écarté");
        Check.True(SchemaRules.CategoryExclusions("person", null).Contains("computer"), "sans schéma lu : schéma de base");
        Check.Contains("écarte computer, qui dérive de user", SchemaRules.RecommendedNote("user", catalog), "note du filtre recommandé");
        Check.Null(SchemaRules.RecommendedNote("contact", catalog), "contact : aucune note");
        Check.Null(SchemaRules.RecommendedNote("site", catalog), "classe sans catégorie usuelle : aucune note");
        Check.Equal("a, b, c et " + FrenchText.Count(2, "autre", "autres"), SchemaRules.ClassList(["a", "b", "c", "d", "e"]), "liste bornée à trois noms");
        Check.Equal("a et b", SchemaRules.ClassList(["a", "b"]), "deux noms");
    }

    [Test]
    public static void Insertion_completes_the_draft_like_Domenia_1()
    {
        var catalog = Catalog();
        var cn = catalog.FindAttribute("cn")!;
        Check.Equal("(cn=valeur*)", LdapFilter.Insert(null, cn, catalog).Filter, "brouillon vide");
        Check.Equal("(&(cn=a)(cn=valeur*))", LdapFilter.Insert("cn=a", cn, catalog).Filter, "ET créé autour d’un filtre sans parenthèses");
        Check.Equal("(&(cn=a)(cn=b)(cn=valeur*))", LdapFilter.Insert("(&(cn=a)(cn=b))", cn, catalog).Filter, "dans le ET");
        Check.Equal("(&(|(cn=a)(cn=b))(cn=valeur*))", LdapFilter.Insert("(|(cn=a)(cn=b))", cn, catalog).Filter, "ET autour d’un OU");
        Check.Equal("(&(cn=()(cn=valeur*))", LdapFilter.Insert("cn=(", cn, catalog).Filter, "filtre invalide : complété puis ET créé, l’analyse le signale");
        var created = LdapFilter.Insert("(cn=a)", catalog.FindAttribute("createTimeStamp")!, catalog);
        Check.False(created.Changed, "calculé : rien d’ajouté");
        var date = LdapFilter.Insert(null, catalog.FindAttribute("pwdLastSet")!, catalog);
        Check.Equal("(pwdLastSet>=133000000000000000)", date.Filter, "exemple FILETIME");
    }
}
