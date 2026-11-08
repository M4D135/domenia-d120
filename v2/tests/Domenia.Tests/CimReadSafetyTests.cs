using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;
using Domenia.Inventory;
using FleetProbes = Domenia.Core.Accueil.ProbeCatalog;

namespace Domenia.Tests;

internal static class CimReadSafetyTests
{
    [Test]
    public static void Every_d1_installer_provider_is_refused_by_workshop_transport_poste_and_fleet_contract()
    {
        Check.Equal(88, CimReadSafety.MsiProviderClassNames.Length, "88 noms repris de la liste D1");
        Check.Equal(88, CimReadSafety.MsiProviderClasses.Count, "aucun doublon masqué");
        var original = FleetProbes.Find("hw.maker")!;
        foreach (var name in CimReadSafety.MsiProviderClassNames)
        {
            Check.True(QueryProbeCatalog.MsiProviderClasses.Contains(name), "atelier : " + name);
            Check.True(PosteLabels.MsiProviderClasses.Contains(name.ToLowerInvariant()), "Poste, insensible à la casse : " + name);
            Check.Throws<QueryDefinitionException>(() => WqlRules.CheckTarget(@"root\cimv2", name), "atelier refuse avant tout lecteur");
            Check.False(CimQuery.IsReadOnlySelect("SELECT Name FROM " + name), "transport refuse avant session : " + name);
            Check.False(FleetProbes.Contract(original with { Class = name }).Valid, "contrat Accueil refuse : " + name);
        }
    }

    [Test]
    public static void Installer_ancestors_are_refused_without_disabling_the_bounded_read_only_leaf_classes()
    {
        foreach (var name in new[] { "Win32_Patch", "Win32_ServiceControl", "Win32_RegistryAction", "CIM_SoftwareElementActions", "CIM_Service" })
        { Check.False(CimQuery.IsReadOnlySelect("SELECT Name FROM " + name), "chemin indirect MSI refusé"); }
        foreach (var name in new[] { "Win32_ComputerSystem", "Win32_BIOS", "Win32_Service", "Win32_QuickFixEngineering" })
        { Check.True(CimQuery.IsReadOnlySelect("SELECT Name FROM " + name), "lecture feuille utile conservée : " + name); }
    }
}
