using Domenia.Core;
using static Domenia.Tests.Fixtures;

namespace Domenia.Tests;

internal static class DirectoryCoverageTests
{
    [Test]
    public static void An_OU_census_never_yields_domain_account_totals()
    {
        var snapshot = Snapshot([User("a")]) with { Coverage = new(Postes, "Postes", true) };
        foreach (var id in new[] { WidgetCatalog.ActiveAccounts, WidgetCatalog.LockedAccounts, WidgetCatalog.PasswordsExpiring })
        {
            var widget = Widget(id, Input(snapshot));
            Check.Null(widget.Data, "aucun faux total du domaine");
            Check.Equal(Tone.Off, widget.Tone, "absence de mesure");
            Check.Null(widget.MeasuredAt, "aucune date de mesure globale");
        }
        Check.Equal(1, Kpi(Widget(WidgetCatalog.ActiveAccounts, Input(snapshot with { Coverage = new(Root, "Domaine", true) }))).Value, "census du domaine");
        Check.Null(Widget(WidgetCatalog.ActiveAccounts, Input(snapshot with { Coverage = null, Complete = false })).Data, "census tronqué");
    }

    [Test]
    public static void Scope_coverage_preserves_depth_and_never_covers_a_parent_or_sibling()
    {
        var branch = new ScopeSelection(Postes, "Postes", true);
        var snapshot = Snapshot() with { Coverage = branch };
        Check.True(snapshot.CoversScope(branch), "même périmètre");
        Check.True(snapshot.CoversScope(branch with { Subtree = false }), "lecture profonde couvre la lecture directe");
        Check.True(snapshot.CoversScope(new("OU=Paris," + Postes, "Paris", true)), "sous-OU couverte");
        Check.False(snapshot.CoversScope(new(Root, "Domaine", true)), "parent non couvert");
        Check.False(snapshot.CoversScope(new(People, "Personnes", true)), "branche voisine non couverte");
        snapshot = snapshot with { Coverage = branch with { Subtree = false } };
        Check.False(snapshot.CoversScope(branch), "pas d’élargissement de profondeur");
        Check.False(snapshot.CoversScope(new("OU=Paris," + Postes, "Paris", false)), "enfants de la sous-OU non lus");
    }

    [Test]
    public static void An_uncovered_working_OU_is_unknown_and_a_partial_read_never_looks_healthy()
    {
        var snapshot = Snapshot(computers: [Computer("PC-1")]) with { Coverage = new(People, "Personnes", true) };
        Check.Null(Widget(WidgetCatalog.OsDistribution, Input(snapshot)).Data, "autre OU inconnue");
        snapshot = snapshot with { Coverage = new(Postes, "Postes", true), Complete = false };
        var partial = Widget(WidgetCatalog.OsDistribution, Input(snapshot));
        Check.True(partial.Data is not null, "objets connus conservés");
        Check.Equal(Tone.Off, partial.Tone, "aucun bilan sain déduit");
        Check.True(partial.Detail.Contains("Relevé partiel", StringComparison.Ordinal), "couverture annoncée");
    }

    [Test]
    public static void Navigation_only_never_fabricates_zero_counts()
    {
        var ou = new DirectoryOu(Guid.NewGuid(), Postes, "Postes", null, null, Now, Now, 1);
        var snapshot = Snapshot() with { OrganizationalUnits = [ou] };
        var navigation = OrganizationalUnitTree.Build(snapshot, objectsRead: false).Find(Postes)!;
        Check.Equal(new OuCounts(null, null, null), navigation.Counts, "objets non lus");
        Check.Equal(new OuCounts(0, 0, 0), OrganizationalUnitTree.Build(snapshot).Find(Postes)!.Counts, "lecture exhaustive vide");
        Check.Equal(new OuCounts(null, null, null), OrganizationalUnitTree.Build(snapshot with { Complete = false }).Find(Postes)!.Counts, "lecture partielle");
    }
}
