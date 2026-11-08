using System.Text.Json.Nodes;
using Domenia.Core.Accueil;

namespace Domenia.Tests;

internal static class ProbeDeclarationTests
{
    private static JsonObject Custom() => JsonNode.Parse("""
    {
      "Id":"custom.manufacturer", "Category":"Personnelles", "Name":"Fabricant déclaré",
      "Namespace":"root\\cimv2", "Class":"Win32_ComputerSystem", "Properties":["Manufacturer"],
      "Filter":"", "Mode":"First", "Transform":"Text", "Visual":"Bar", "Slow":true, "SkipOnDc":true,
      "Origin":"Personnalisée", "Description":"Fabricant rapporté par le fournisseur.", "Rights":"Compte autorisé sur la cible.",
      "Compatibility":"Windows avec CIMWin32.", "UnknownMeaning":"Absence ou refus : inconnu.", "Limitations":"Matériel présenté à Windows seulement.",
      "SourceUrls":["https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem"],
      "Fields":[{"Name":"Manufacturer","CimType":"string","Kind":"Text","IsArray":false,"Unit":"","Description":"Nom rapporté."}],
      "Behavior":{"Reads":"CIM","Writes":false,"Code":"Aucun","Methods":[],"Target":"Liste de postes explicitement choisie."},
      "Privilege":{"Level":"AdministrateurLocal","Text":"Délégation à qualifier : administrateur local exigé par cette déclaration."},
      "Cost":{"Level":"Léger","Reason":"Une instance ; collecte conservée explicite."}
    }
    """)!.AsObject();

    private static string Catalog(params JsonObject[] probes) => new JsonObject
    {
        ["SchemaVersion"] = 1,
        ["Probes"] = new JsonArray(probes.Select(p => (JsonNode)p).ToArray()),
    }.ToJsonString();

    [Test]
    public static void Embedded_catalog_is_loaded_through_the_checked_path()
    {
        Check.True(ProbeCatalog.All.Length >= 100, "catalogue embarqué effectivement chargé");
        foreach (var probe in ProbeCatalog.All)
        {
            var contract = ProbeCatalog.Contract(probe);
            Check.True(contract.Valid, probe.Id + " : " + string.Join(" ", contract.Errors));
            Check.Equal(probe, ProbeCatalog.Find(probe.Id), "même définition immuable indexée");
        }
    }

    [Test]
    public static void Custom_origin_privilege_cost_and_target_are_never_inferred_from_the_class()
    {
        var probe = ProbeCatalog.ReadDetailed(Catalog(Custom())).Single();
        var contract = ProbeCatalog.Contract(probe);
        Check.Equal("Personnalisée", probe.Origin, "origine conservée");
        Check.True(contract.Valid, "déclaration complète acceptée");
        Check.Equal("AdministrateurLocal", contract.PrivilegeLevel, "droit explicite malgré root/cimv2");
        Check.Equal("Léger", contract.CostLevel, "coût déclaré conservé malgré Slow");
        Check.True(contract.Lines.Any(l => l.Section == "Comportement" && l.Value.Contains("Liste de postes explicitement choisie.", StringComparison.Ordinal)), "cible explicitement déclarée affichée");
        Check.Null(ProbeCatalog.Find(probe.Id), "lire une définition ne modifie pas le catalogue global ou un autre profil");
    }

    [Test]
    public static void Every_custom_declaration_is_required_before_loading()
    {
        foreach (var name in new[] { "Behavior", "Privilege", "Cost", "Slow", "SkipOnDc" })
        {
            var probe = Custom(); probe.Remove(name);
            Check.Throws<InvalidDataException>(() => ProbeCatalog.ReadDetailed(Catalog(probe)), name + " absent : refus au chargement");
        }
        foreach (var name in new[] { "Slow", "SkipOnDc" })
        {
            var probe = Custom(); probe[name] = false;
            Check.Throws<InvalidDataException>(() => ProbeCatalog.ReadDetailed(Catalog(probe)), name + " faux : refus au chargement");
        }
        var contract = ProbeCatalog.Contract(ProbeCatalog.All[0] with { Origin = "Personnalisée" });
        Check.False(contract.Valid, "origine personnalisée créée directement aussi refusée sans déclarations");
        Check.Equal("", contract.PrivilegeLevel, "aucun privilège déduit");
        Check.Equal("", contract.CostLevel, "aucun coût déduit");
    }

    [Test]
    public static void Custom_behavior_cannot_contain_code_methods_writes_or_an_implicit_target()
    {
        foreach (var change in new Action<JsonObject>[]
        {
            p => p["Behavior"]!["Reads"] = "Registry", p => p["Behavior"]!["Writes"] = true,
            p => p["Behavior"]!["Code"] = "PowerShell", p => p["Behavior"]!["Methods"] = new JsonArray("Invoke"),
            p => p["Behavior"]!.AsObject().Remove("Target"), p => p["Behavior"]!["Target"] = "",
            p => p["Privilege"]!["Level"] = "Inconnu", p => p["Cost"]!["Level"] = "Gratuit",
        })
        {
            var probe = Custom(); change(probe);
            Check.Throws<InvalidDataException>(() => ProbeCatalog.ReadDetailed(Catalog(probe)), "déclaration non conforme refusée sans lecteur");
        }
    }

    [Test]
    public static void Loader_refuses_ambiguous_json_types_and_unknown_properties()
    {
        foreach (var change in new Action<JsonObject>[]
        {
            p => p["Origin"] = "Inconnue", p => p["Slow"] = "true", p => p["SkipOnDc"] = null,
            p => p["Properties"] = new JsonArray("Manufacturer", 1), p => p["Script"] = "ignored code",
            p => p["Behavior"]!["Writes"] = "false", p => p["Fields"]![0]!["IsArray"] = true,
            p => p["Fields"]![0]!["CimType"] = "object", p => p["Properties"] = new JsonArray("Manufacturer", "manufacturer"),
        })
        {
            var probe = Custom(); change(probe);
            Check.Throws<InvalidDataException>(() => ProbeCatalog.ReadDetailed(Catalog(probe)), "JSON ambigu jamais partiellement interprété");
        }
        var raw = Catalog(Custom());
        Check.Throws<InvalidDataException>(() => ProbeCatalog.ReadDetailed(raw.Insert(1, "\"SchemaVersion\":1,")), "clé racine répétée");
        Check.Throws<InvalidDataException>(() => ProbeCatalog.ReadDetailed(Catalog(Custom(), Custom())), "sonde répétée");
        Check.Throws<InvalidDataException>(() => ProbeCatalog.ReadDetailed(raw.Replace("\"SchemaVersion\":1", "\"SchemaVersion\":\"1\"", StringComparison.Ordinal)), "version numérique requise");
    }

    [Test]
    public static void Custom_catalog_is_bounded_and_refuses_forbidden_provider_or_projection()
    {
        foreach (var change in new Action<JsonObject>[]
        {
            p => p["Class"] = "Win32_Product", p => p["Namespace"] = "root\\subscription",
            p => p["Properties"] = new JsonArray("Manufacturer FROM Win32_Product"),
            p => p["Filter"] = "Manufacturer = 'x'; DELETE", p => p["Filter"] = "Date > '{UNKNOWN}'",
            p => p["Transform"] = "Run:script", p => p["Name"] = new string('a', 257),
        })
        {
            var probe = Custom(); change(probe);
            Check.Throws<InvalidDataException>(() => ProbeCatalog.ReadDetailed(Catalog(probe)), "fournisseur, projection ou borne refusé");
        }
        Check.Throws<InvalidDataException>(() => ProbeCatalog.ReadDetailed(new string(' ', 1_048_577)), "borne avant parsing");
    }
}
