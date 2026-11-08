using System.Collections.Immutable;

namespace Domenia.Tests;

internal static class NativeAcceptanceReadSelectionTests
{
    [Test]
    public static void Critical_native_selection_is_explicit_and_reports_every_omitted_read()
    {
        var selected = NativeAcceptanceReadSelection.FromMode("--critical-canary");
        Check.Equal("critical-only", selected.Kind, "mode critique explicite");
        Check.True(selected.CanaryRequested, "consentement canari explicite");
        Check.True(selected.Selected.SequenceEqual(["directory.scope", "audit.machineIdentity", "operations.history", "poste.inventory"]), "quatre lectures critiques bornées");
        Check.Equal(26, selected.NotExecuted.Length, "vingt-six lectures non exécutées affichées");
        Check.False(selected.Selected.Intersect(selected.NotExecuted, StringComparer.Ordinal).Any(), "aucun résultat retenu/omis ambigu");
        Check.True(selected.Selected.Concat(selected.NotExecuted).Order(StringComparer.Ordinal).SequenceEqual(NativeAcceptanceReadSelection.Available.Order(StringComparer.Ordinal)), "chaque contrat est retenu ou non exécuté");
        Check.False(NativeAcceptanceReadSelection.FromMode("--critical-read-only").CanaryRequested, "lecture seule jamais transformée en canari");
    }

    [Test]
    public static void Empty_unknown_or_repeated_native_selection_is_refused_without_a_reader()
    {
        foreach (var mode in new[] { "", "critical", "--all", "--critical-canary-extra" })
        { Check.Throws<InvalidDataException>(() => NativeAcceptanceReadSelection.FromMode(mode), "mode inconnu refusé avant tout lecteur"); }
        foreach (var selection in new ImmutableArray<string>[] { default, [], ["not-known"], ["directory.scope", "directory.scope"] })
        { Check.Throws<InvalidDataException>(() => NativeAcceptanceReadSelection.Validate(selection), "sélection vide, inconnue ou doublonnée refusée"); }
    }

    [Test]
    public static void Legacy_native_selection_never_claims_to_be_critical()
    {
        var legacy = NativeAcceptanceReadSelection.FromMode("--read-only");
        Check.Equal("complete", legacy.Kind, "ancienne sélection explicitement complète");
        Check.Equal(30, legacy.Selected.Length, "liste historique conservée");
        Check.True(legacy.NotExecuted.IsEmpty, "aucune omission dans la liste historique");
        Check.False(legacy.CanaryRequested, "aucun consentement d’écriture implicite");
    }

    [Test]
    public static async Task Evidence_never_invokes_an_omitted_read_or_accepts_a_partial_critical_pass()
    {
        using var folder = new TemporaryFolder();
        var selection = NativeAcceptanceReadSelection.FromMode("--critical-read-only");
        using var evidence = new NativeAcceptanceEvidence(folder.File("selection.jsonl"), TestClock.Fixed(), selection);
        evidence.BeforeRead = _ => Task.CompletedTask;
        var calls = 0;
        Task<int> Read(CancellationToken _) { calls++; return Task.FromResult(0); }
        await Check.ThrowsAsync<InvalidDataException>(() => evidence.Read("audit.services", Read), "lecture non critique jamais appelée");
        Check.Equal(0, calls, "aucun contact omis exécuté");
        Check.Throws<InvalidDataException>(() => evidence.Finish(false), "sélection vide non présentée comme terminée");
        foreach (var operation in selection.Selected) { await evidence.Read(operation, Read); }
        Check.Equal(4, calls, "les quatre lectures seulement");
        await Check.ThrowsAsync<InvalidDataException>(() => evidence.Read("directory.scope", Read), "aucune lecture rejouée");
        Check.Throws<InvalidDataException>(() => evidence.Finish(true), "consentement canari jamais inventé");
        evidence.Finish(false);
    }
}
