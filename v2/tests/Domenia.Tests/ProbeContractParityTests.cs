using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Tests;

internal static class ProbeContractParityTests
{
    private static ProbeDefinition Reference() => ProbeCatalog.All.First(p => p.Class == "Win32_ComputerSystem") with
    {
        Origin = "Catalogue détaillé", Namespace = @"root\cimv2", Class = "Win32_ComputerSystem",
        Properties = ["Name"], Fields = [new("Name", "string", "Text", false, "", "Nom rapporté.")],
        Filter = "", Mode = "First", Transform = "Text", Slow = false, SkipOnDc = false,
        Behavior = new("CIM", false, "Aucun", [], "Poste explicitement choisi."),
        Privilege = new("LectureDistanteWmi", "Lecture distante autorisée par le poste."),
        Cost = new("Léger", "Une instance."),
        SourceUrls = ["https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem"],
    };

    private static void Refused(ProbeDefinition probe, string reason)
    {
        var contract = ProbeCatalog.Contract(probe);
        Check.False(contract.Valid, reason);
        Check.True(contract.Errors.Any(e => e.Contains(reason, StringComparison.OrdinalIgnoreCase)),
            "motif attendu : " + reason + " ; reçu : " + string.Join(" · ", contract.Errors));
    }

    [Test]
    public static void Contract_refuses_every_msi_provider_class_and_forbidden_namespace_family()
    {
        var probe = Reference();
        Check.True(ProbeCatalog.Contract(probe).Valid, "témoin valide");
        foreach (var name in CimReadSafety.MsiProviderClassNames.Append("Win32_ReliabilityRecords"))
        { Refused(probe with { Class = name.ToLowerInvariant() }, "Classe refusée"); }
        foreach (var space in new[] { @"root\subscription", @"root\directory\LDAP", @"root\RSOP", @"root\default", @"root\security" })
        {
            Refused(probe with { Namespace = space.ToUpperInvariant() }, "Espace de noms refusé");
            Refused(probe with { Namespace = space + @"\Nested" }, "Espace de noms refusé");
        }
    }

    [Test]
    public static void Local_account_guard_is_case_insensitive_and_requires_a_real_restriction()
    {
        var probe = Reference();
        foreach (var name in new[] { "Win32_UserAccount", "win32_useraccount", "WIN32_GROUP", "Win32_GROUPUSER" })
        {
            foreach (var filter in new[] { "", "Name='LocalAccount=TRUE'", "NotLocalAccount=TRUE", "NOT LocalAccount=TRUE",
                "LocalAccount=TRUE OR LocalAccount=FALSE", "LocalAccount=TRUE AND Name='x' OR Name='y'",
                "Name='x' OR LocalAccount=TRUE", "LocalAccount=TRUEish", "LocalAccount=FALSE" })
            { Refused(probe with { Class = name, Filter = filter }, "Comptes et groupes"); }
        }
    }

    [Test]
    public static void Local_account_conjunctions_and_explicit_controller_exclusion_remain_accepted()
    {
        var probe = Reference() with { Class = "win32_useraccount" };
        foreach (var filter in new[] { "LocalAccount=TRUE", "  localaccount = true  ",
            "LocalAccount=TRUE AND Disabled=FALSE", "LocalAccount=TRUE AND Name='OR NOT LocalAccount=FALSE'" })
        {
            var contract = ProbeCatalog.Contract(probe with { Filter = filter });
            Check.True(contract.Valid, "restriction locale conservée : " + filter + " ; " + string.Join(" · ", contract.Errors));
        }
        Check.True(ProbeCatalog.Contract(probe with { SkipOnDc = true }).Valid, "alternative historique : contrôleurs exclus");
    }

    [Test]
    public static void Contract_allows_only_declarative_cim_without_writes_code_or_methods()
    {
        var probe = Reference();
        foreach (var behavior in new[]
        {
            probe.Behavior! with { Reads = "Registry" }, probe.Behavior! with { Writes = true },
            probe.Behavior! with { Code = "PowerShell" }, probe.Behavior! with { Methods = ["Invoke"] },
            probe.Behavior! with { Methods = default }, probe.Behavior! with { Target = " " },
        })
        { Refused(probe with { Behavior = behavior }, "Comportement refusé"); }
    }

    [Test]
    public static void Heavy_cost_requires_explicit_collection_and_privilege_and_cost_must_be_declared()
    {
        var probe = Reference() with { Cost = new("Lourd", "Journal volumineux.") };
        Refused(probe, "Coût lourd sans collecte explicite");
        Check.True(ProbeCatalog.Contract(probe with { Slow = true }).Valid, "coût lourd explicitement collecté");
        Refused(Reference() with { Privilege = new("Inconnu", "Droit non qualifié.") }, "Privilèges inconnus");
        Refused(Reference() with { Cost = new("Léger", " ") }, "Coût inconnu");
        Refused(Reference() with { Origin = "Personnalisée", Behavior = null, Privilege = null, Cost = null }, "doivent être déclarés");
    }

    [Test]
    public static void Projection_and_filter_bounds_and_declared_types_are_enforced()
    {
        var probe = Reference();
        Refused(probe with { Properties = [] }, "Nombre de propriétés");
        var properties = Enumerable.Range(0, 64).Select(i => "Field" + i).ToImmutableArray();
        var fields = properties.Select(p => new ProbeField(p, "string", "Text", false, "", "Champ.")).ToImmutableArray();
        Check.True(ProbeCatalog.Contract(probe with { Properties = properties, Fields = fields }).Valid, "64 propriétés typées admises");
        Refused(probe with { Properties = properties.Add("Extra"), Fields = fields.Add(new("Extra", "string", "Text", false, "", "Champ.")) }, "Nombre de propriétés");
        Refused(probe with { Properties = ["Name", "name"] }, "Propriétés répétées");
        Refused(probe with { Fields = [] }, "Propriété sans type déclaré");
        Refused(probe with { Fields = [new("Name", "string", "Code", false, "", "Champ.")] }, "types de champs invalides");
        Check.True(ProbeCatalog.Contract(probe with { Filter = "Name='" + new string('x', 505) + "'" }).Valid, "filtre de 512 caractères admis");
        Refused(probe with { Filter = "Name='" + new string('x', 506) + "'" }, "Filtre trop long");
        Refused(probe with { Filter = "Name='x'; DELETE" }, "caractère non admis");
    }

    [Test]
    public static void Only_declared_time_windows_and_microsoft_sources_are_accepted()
    {
        var probe = Reference();
        foreach (var token in new[] { "{SINCE_24H}", "{SINCE_7D}" })
        {
            var contract = ProbeCatalog.Contract(probe with { Filter = "TimeGenerated>='" + token + "'" });
            Check.True(contract.Valid, "jeton documenté accepté");
            Check.True(contract.Lines.Any(l => l.Section == "Tests attendus" && l.Value.Contains("Fenêtre", StringComparison.Ordinal)), "test de résolution exigé");
        }
        foreach (var token in new[] { "{SINCE_1H}", "{SINCE_24H", "SINCE_7D}", "{UNKNOWN}" })
        { Refused(probe with { Filter = "Date='" + token + "'" }, "Jeton de filtre"); }
        Refused(probe with { SourceUrls = [] }, "Référence documentaire primaire");
        Refused(probe with { SourceUrls = ["https://learn.microsoft.com.example.org/class"] }, "Référence documentaire non autorisée");
        Check.True(ProbeCatalog.Contract(probe with { SourceUrls = ["https://github.com/MicrosoftDocs/win32"] }).Valid, "source Microsoft admise");
    }

    [Test]
    public static void Contract_exposes_privilege_cost_behavior_sources_and_expected_failure_tests()
    {
        var contract = ProbeCatalog.Contract(Reference() with { SkipOnDc = true });
        Check.True(contract.Valid, "contrat valide");
        Check.Equal("LectureDistanteWmi", contract.PrivilegeLevel, "privilège déclaré");
        Check.Equal("Léger", contract.CostLevel, "coût déclaré");
        foreach (var section in new[] { "Types", "Privilèges", "Coût", "Comportement", "Sources", "Isolement" })
        { Check.True(contract.Lines.Any(l => l.Section == section && l.Value.Length > 0), "section " + section); }
        var expected = contract.Lines.Single(l => l.Section == "Tests attendus").Value;
        foreach (var name in new[] { "Projection", "Inconnu", "Refus", "Troncature", "Contrôleur" })
        { Check.Contains(name, expected, "cas attendu " + name); }
    }
}
