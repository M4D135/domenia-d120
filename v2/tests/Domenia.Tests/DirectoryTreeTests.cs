using System.Text.Json;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class DirectoryTreeTests
{
    private const string Root = "DC=example,DC=local";
    private const string Postes = "OU=Postes,DC=example,DC=local";
    private const string Sep = FrenchText.PathSeparator;

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static JsonElement Children(JsonElement result) => result.GetProperty("children");

    private static JsonElement Item(JsonElement children, string name) => children.EnumerateArray().Single(c => c.GetProperty("name").GetString() == name);

    [Test]
    public static async Task Root_children_have_the_contract_shape()
    {
        var bridge = new SimulatedBridge();
        var json = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.children", "{\"dn\":null}"));
        Check.True(Names(json).SequenceEqual(["parent", "children"]), "propriétés du résultat");
        var parent = json.GetProperty("parent");
        Check.True(Names(parent).SequenceEqual(["dn", "name", "path"]), "propriétés du parent");
        Check.Equal(Root, parent.GetProperty("dn").GetString(), "racine du domaine");
        Check.Equal("example.local", parent.GetProperty("name").GetString(), "nom de la racine");
        Check.Equal("example.local", parent.GetProperty("path").GetString(), "chemin de la racine");
        string[] names = [.. Children(json).EnumerateArray().Select(c => c.GetProperty("name").GetString()!)];
        Check.True(names.SequenceEqual(["Comptes à privilèges", "Comptes de service", "Domain Controllers", "Groupes", "Postes", "Serveurs", "Utilisateurs"]),
            "sept OU à la racine, ordre français : " + string.Join(", ", names));
        var postes = Item(Children(json), "Postes");
        Check.True(Names(postes).SequenceEqual(["dn", "name", "path", "hasChildren", "counts"]), "propriétés d’une OU");
        Check.True(Names(postes.GetProperty("counts")).SequenceEqual(["users", "computers", "groups"]), "propriétés des nombres");
        Check.Equal(Postes, postes.GetProperty("dn").GetString(), "DN de Postes");
        Check.Equal("example.local" + Sep + "Postes", postes.GetProperty("path").GetString(), "chemin lisible");
        Check.True(postes.GetProperty("hasChildren").GetBoolean(), "Postes a des sous-OU");
        Check.Equal(431, postes.GetProperty("counts").GetProperty("computers").GetInt32(), "postes actifs et en quarantaine");
        Check.Equal(0, postes.GetProperty("counts").GetProperty("users").GetInt32(), "aucun utilisateur");
        var people = Item(Children(json), "Utilisateurs");
        Check.Equal(1236, people.GetProperty("counts").GetProperty("users").GetInt32(), "personnes, sous-OU comprises");
        Check.Equal(58, Item(Children(json), "Groupes").GetProperty("counts").GetProperty("groups").GetInt32(), "groupes des OU de groupes");
        Check.Equal(13, Item(Children(json), "Comptes de service").GetProperty("counts").GetProperty("users").GetInt32(), "comptes de service");
        Check.False(Item(Children(json), "Comptes de service").GetProperty("hasChildren").GetBoolean(), "aucune sous-OU");
    }

    [Test]
    public static async Task Absent_arguments_name_the_root_and_children_follow_the_tree()
    {
        var bridge = new SimulatedBridge();
        var root = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.children", "{}"));
        Check.Equal(Root, root.GetProperty("parent").GetProperty("dn").GetString(), "dn absent : racine");
        var byRootDn = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.children", "{\"dn\":\"dc=EXAMPLE,dc=local\"}"));
        Check.Equal(Children(root).GetRawText(), Children(byRootDn).GetRawText(), "racine nommée, casse ignorée");

        var postes = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.children", "{\"dn\":\"" + Postes + "\"}"));
        Check.Equal("example.local" + Sep + "Postes", postes.GetProperty("parent").GetProperty("path").GetString(), "chemin du parent");
        string[] sites = [.. Children(postes).EnumerateArray().Select(c => c.GetProperty("name").GetString()!)];
        Check.True(sites.SequenceEqual(["Bordeaux", "Lille", "Lyon", "Marseille", "Paris", "Quarantaine"]), "sites : " + string.Join(", ", sites));
        var paris = Item(Children(postes), "Paris");
        Check.Equal("example.local" + Sep + "Postes" + Sep + "Paris", paris.GetProperty("path").GetString(), "chemin de Paris");
        Check.Equal(186, paris.GetProperty("counts").GetProperty("computers").GetInt32(), "postes de Paris");
        Check.False(paris.GetProperty("hasChildren").GetBoolean(), "feuille");
        Check.Equal(19, Item(Children(postes), "Quarantaine").GetProperty("counts").GetProperty("computers").GetInt32(), "quarantaine");

        var leaf = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.children", "{\"dn\":\"" + paris.GetProperty("dn").GetString() + "\"}"));
        Check.Equal(0, Children(leaf).GetArrayLength(), "aucune sous-OU");
    }

    [Test]
    public static async Task Accented_and_escaped_names_keep_their_text()
    {
        var bridge = new SimulatedBridge();
        var groups = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.children", "{\"dn\":\"OU=Groupes,DC=example,DC=local\"}"));
        var security = Item(Children(groups), "Sécurité");
        Check.Equal("example.local" + Sep + "Groupes" + Sep + "Sécurité", security.GetProperty("path").GetString(), "accent conservé");
        Check.Equal(28, security.GetProperty("counts").GetProperty("groups").GetInt32(), "groupes de sécurité");
        // The DN given back by the tree can be sent again as is.
        var again = await bridge.CallAsync("directory.ou.children", JsonSerializer.Serialize(new { dn = security.GetProperty("dn").GetString() }));
        Check.Equal("result", again.Kind, "DN rendu réutilisable");
    }

    [Test]
    public static async Task Children_refuse_unknown_and_malformed_names()
    {
        var bridge = new SimulatedBridge();
        var unknown = await bridge.CallAsync("directory.ou.children", "{\"dn\":\"OU=Nulle part,DC=example,DC=local\"}");
        Check.Equal(DomeniaErrors.OuUnknown, unknown.Error!.Code, "OU inconnue");
        Check.Equal(DomeniaErrors.OuUnknownMessage, unknown.Error.Message, "message du contrat");
        Check.Equal(DomeniaErrors.OuUnknown, (await bridge.CallAsync("directory.ou.children", "{\"dn\":\"CN=Users,DC=example,DC=local\"}")).Error!.Code, "un conteneur n’est pas une OU");
        Check.Equal(DomeniaErrors.OuUnknown, (await bridge.CallAsync("directory.ou.children", "{\"dn\":\"OU=Postes,DC=autre,DC=local\"}")).Error!.Code, "autre domaine");
        foreach (var args in new[] { "{\"dn\":\"pas un DN\"}", "{\"dn\":3}", "{\"dn\":\"\"}", "{\"dn\":null,\"x\":1}", "[]", "{\"dn\":\"OU=" + new string('a', 2100) + "\"}" })
        {
            var refused = await bridge.CallAsync("directory.ou.children", args);
            Check.Equal(DomeniaErrors.ArgumentsInvalid, refused.Error!.Code, "arguments refusés : " + args[..Math.Min(args.Length, 40)]);
            Check.False(refused.Error.Message.Contains("pas un DN", StringComparison.Ordinal), "saisie jamais recopiée");
        }
    }

    [Test]
    public static async Task Search_ignores_accents_and_case_and_returns_the_same_items()
    {
        var bridge = new SimulatedBridge();
        var security = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.search", "{\"text\":\"SECURITE\"}"));
        Check.Equal(JsonValueKind.Array, security.ValueKind, "la réponse est la liste des OU");
        Check.Equal(1, security.GetArrayLength(), "une OU Sécurité");
        Check.True(Names(security[0]).SequenceEqual(["dn", "name", "path", "hasChildren", "counts"]), "même forme que les enfants");

        var paris = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.search", "{\"text\":\"paris\"}"));
        // Utilisateurs › Paris, its eight services (path) and Postes › Paris.
        Check.Equal(10, paris.GetArrayLength(), "nom ou chemin");
        var privileged = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.search", "{\"text\":\"a privileges\"}"));
        Check.Equal("Comptes à privilèges", privileged[0].GetProperty("name").GetString(), "accent ignoré dans la saisie");
        var none = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.search", "{\"text\":\"   \"}"));
        Check.Equal(0, none.GetArrayLength(), "texte vide : rien");
        var all = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.search", "{\"text\":\"example\"}"));
        Check.Equal(39, all.GetArrayLength(), "39 OU, sous la limite de 50");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("directory.ou.search", "{\"text\":\"" + new string('x', 101) + "\"}")).Error!.Code, "texte trop long");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("directory.ou.search", "{}")).Error!.Code, "texte obligatoire");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("directory.ou.search", "{\"text\":1}")).Error!.Code, "texte non textuel");
    }

    [Test]
    public static void Search_is_bounded_and_says_when_it_is()
    {
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed());
        var tree = OrganizationalUnitTree.Build(source.World.Directory);
        Check.Equal(39, tree.Count, "39 OU");
        var all = tree.Search("example", 50);
        Check.Equal(39, all.Results.Length, "toutes par le chemin");
        Check.False(all.Truncated, "sous la limite");
        var few = tree.Search("example", 5);
        Check.Equal(5, few.Results.Length, "limite respectée");
        Check.True(few.Truncated, "limite signalée");
        string[] paths = [.. all.Results.Select(r => r.Path)];
        Check.True(paths.SequenceEqual(paths.Order(StringComparer.Create(System.Globalization.CultureInfo.GetCultureInfo("fr-FR"), System.Globalization.CompareOptions.IgnoreCase))), "ordre des chemins");
    }

    [Test]
    public static void Tree_of_a_hand_written_snapshot()
    {
        DirectoryOu Ou(string dn, string name) => new(Fixtures.IdOf(dn), dn, name, null, null, Fixtures.Now, Fixtures.Now, 1);
        var snapshot = Fixtures.Snapshot(
            users: [Fixtures.User("Alice") with { DistinguishedName = "CN=Alice,OU=Sous,OU=Haut,DC=test,DC=local" }],
            computers: [Fixtures.Computer("PC1", "OU=Haut,DC=test,DC=local"), Fixtures.Computer("PC2", "CN=Computers,DC=test,DC=local")]) with
        {
            OrganizationalUnits =
            [
                Ou("OU=Haut,DC=test,DC=local", "Haut"),
                Ou("OU=Sous,OU=Haut,DC=test,DC=local", "Sous"),
                Ou("OU=Ailleurs,DC=autre,DC=local", "Ailleurs"),
                Ou("OU=Virgule\\, oui,DC=test,DC=local", "Virgule, oui"),
            ],
        };
        var tree = OrganizationalUnitTree.Build(snapshot);
        Check.Equal(3, tree.Count, "OU d’un autre domaine écartée");
        var root = tree.Children(null)!;
        Check.True(root.Children.Select(c => c.Name).SequenceEqual(["Haut", "Virgule, oui"]), "racine");
        var haut = root.Children[0];
        Check.Equal(new OuCounts(1, 1, 0), haut.Counts, "sous-OU comprise, conteneur exclu");
        Check.NotNull(tree.Find("ou=virgule\\2C oui,dc=TEST,dc=local"), "échappement et casse ignorés");
        Check.Null(tree.Find("CN=Computers,DC=test,DC=local"), "conteneur");
        Check.Null(tree.Find("n’importe quoi"), "DN mal formé");
        Check.True(tree.IsRoot("dc=test,dc=local"), "racine reconnue");
        Check.Null(tree.Children("OU=Absente,DC=test,DC=local"), "OU absente");
    }

    [Test]
    public static void Folding_ignores_accents_ligatures_and_case()
    {
        Check.Equal("securite", FrenchText.Fold("Sécurité"), "accents");
        Check.Equal("oeuvre", FrenchText.Fold("Œuvre"), "ligature");
        Check.Equal("d'almeida", FrenchText.Fold("D’Almeida"), "apostrophe typographique");
        Check.Equal("comptes a privileges", FrenchText.Fold("Comptes à privilèges"), "phrase");
        Check.Equal("a\ud800b", FrenchText.Fold("A\ud800B"), "texte Unicode invalide : jamais d’exception");
    }
}
