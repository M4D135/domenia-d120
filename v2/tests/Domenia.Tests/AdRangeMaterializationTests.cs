using System.Collections;
using System.DirectoryServices.Protocols;
using System.Globalization;
using System.Reflection;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdRangeMaterializationTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly Guid Identity = Fixtures.IdOf("range-object");
    private const string Dn = "CN=Groupe-fictif," + Fixtures.Postes;

    private static AdEntry Entry(string name, IReadOnlyList<object> values, bool emptyFirst = true, bool companion = true,
        Guid? identity = null, string? version = "42", string dn = Dn)
    {
        var attributes = new Dictionary<string, IReadOnlyList<object>>(StringComparer.OrdinalIgnoreCase);
        if (companion && emptyFirst) { attributes.Add("member", []); }
        attributes.Add(name, values);
        if (companion && !emptyFirst) { attributes.Add("member", []); }
        attributes.Add("objectGUID", [(identity ?? Identity).ToByteArray()]);
        if (version is not null) { attributes.Add("uSNChanged", [version]); }
        return new(dn, attributes);
    }

    private static Task<IReadOnlyList<AdEntry>> Unexpected(string _, CancellationToken __) => throw new InvalidOperationException("Aucune suite attendue.");

    [Test]
    public static async Task Standard_AD_empty_companion_and_terminal_range_materialize_in_both_orders()
    {
        foreach (var emptyFirst in new[] { false, true })
        {
            // Use the actual Protocols collection, including its empty DirectoryAttribute representation.
            var entry = (SearchResultEntry)Activator.CreateInstance(typeof(SearchResultEntry), BindingFlags.Instance | BindingFlags.NonPublic,
                binder: null, args: [Dn], culture: CultureInfo.InvariantCulture)!;
            var attributes = (IDictionary)entry.Attributes;
            if (emptyFirst) { attributes.Add("member", new DirectoryAttribute { Name = "member" }); }
            attributes.Add("member;range=0-*", new DirectoryAttribute("member;range=0-*", "CN=A," + Fixtures.Postes, "CN=B," + Fixtures.Postes));
            if (!emptyFirst) { attributes.Add("member", new DirectoryAttribute { Name = "member" }); }
            var raw = AdConnection.ReadEntry(entry);
            var result = await AdConnection.MaterializeEntryAsync(raw, Unexpected, None, maximum: 2);
            Check.Equal(2, result.Raw("member").Count, "attribut complet à la limite exacte");
            Check.False(result.AttributeNames.Any(n => n.Contains(';')), "pas de tranche publiée comme attribut complet");
        }
    }

    [Test]
    public static async Task Successive_ranges_keep_identity_and_request_bounds_and_publish_only_the_terminal_result()
    {
        var requests = new List<string>();
        var result = await AdConnection.MaterializeEntryAsync(Entry("member;range=0-1", ["A", "B"]), (requested, _) =>
        {
            requests.Add(requested);
            return Task.FromResult<IReadOnlyList<AdEntry>>(requests.Count == 1
                ? [Entry("member;range=2-3", ["C", "D"])] : [Entry("member;range=4-*", ["E"], emptyFirst: false)]);
        }, None, maximum: 5);
        Check.True(requests.SequenceEqual(new[] { "member;range=2-4", "member;range=4-4" }), "bornes successives sans élargissement");
        Check.True(result.Strings("member").SequenceEqual(new[] { "A", "B", "C", "D", "E" }), "toutes les valeurs publiées une seule fois");
        Check.Equal(Identity, result.Guid("objectGUID"), "identité conservée");
    }

    [Test]
    public static async Task Nonempty_plain_companion_or_multiple_ranges_remain_ambiguous_and_refused()
    {
        var raw = Entry("member;range=0-*", ["A"]);
        foreach (var extra in new[] { "member", "member;range=1-*" })
        {
            var attributes = raw.AttributeNames.ToDictionary(n => n, raw.Raw, StringComparer.OrdinalIgnoreCase);
            attributes[extra] = new object[] { "B" };
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => AdConnection.MaterializeEntryAsync(new(Dn, attributes), Unexpected, None), "doublon réel refusé");
            Check.Contains("cause=réponse-attribut-ambiguë", error.Message, "cause exploitable");
        }
    }

    [Test]
    public static async Task Gaps_overlap_wrong_counts_duplicates_and_unqualified_continuations_are_refused()
    {
        var invalid = new[]
        {
            Entry("member;range=3-*", ["C"]), Entry("member;range=1-*", ["C"]),
            Entry("member;range=2-3", ["C"]), Entry("member;range=2-*", ["B"]),
            Entry("member", ["C"], companion: false),
        };
        foreach (var next in invalid)
        {
            var calls = 0;
            await Check.ThrowsAsync<DomeniaOperationException>(() => AdConnection.MaterializeEntryAsync(Entry("member;range=0-1", ["A", "B"]), (_, _) =>
            { calls++; return Task.FromResult<IReadOnlyList<AdEntry>>([next]); }, None, maximum: 4), "suite incohérente refusée");
            Check.Equal(1, calls, "aucun réessai caché");
        }
    }

    [Test]
    public static async Task Changed_or_missing_identity_and_version_abort_without_retry_or_partial_publication()
    {
        foreach (var next in new[]
        {
            Entry("member;range=2-*", ["C"], identity: Guid.NewGuid()),
            Entry("member;range=2-*", ["C"], version: "43"),
            Entry("member;range=2-*", ["C"], version: null),
            Entry("member;range=2-*", ["C"], identity: Guid.Empty),
            Entry("member;range=2-*", ["C"], dn: "CN=Autre," + Fixtures.Postes),
        })
        {
            var calls = 0;
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => AdConnection.MaterializeEntryAsync(Entry("member;range=0-1", ["A", "B"]), (_, _) =>
            { calls++; return Task.FromResult<IReadOnlyList<AdEntry>>([next]); }, None), "objet changé ou non qualifié");
            Check.True(error.Message.Contains("cause=objet-modifié", StringComparison.Ordinal) || error.Message.Contains("cause=cohérence-suite-absente", StringComparison.Ordinal), "cause stable");
            Check.Equal(1, calls, "un seul envoi de suite");
        }
        var missing = await Check.ThrowsAsync<DomeniaOperationException>(() => AdConnection.MaterializeEntryAsync(
            Entry("member;range=0-1", ["A", "B"], version: null), Unexpected, None), "pas de suite sans USN initial");
        Check.Contains("USN=absent", missing.Message, "absence identifiée");
    }

    [Test]
    public static async Task Exact_limits_require_a_terminal_slice_and_plain_multivalues_obey_the_same_cap()
    {
        await AdConnection.MaterializeEntryAsync(Entry("member;range=0-*", ["A", "B"]), Unexpected, None, maximum: 2);
        await AdConnection.MaterializeEntryAsync(Entry("member", ["A", "B"], companion: false), Unexpected, None, maximum: 2);
        foreach (var raw in new[] { Entry("member;range=0-1", ["A", "B"]), Entry("member;range=0-*", ["A", "B", "C"]), Entry("member", ["A", "B", "C"], companion: false) })
        { await Check.ThrowsAsync<DomeniaOperationException>(() => AdConnection.MaterializeEntryAsync(raw, Unexpected, None, maximum: 2), "limite exacte ou dépassée sans contournement"); }
    }

    [Test]
    public static void Fiche_projection_preserves_a_partial_range_with_its_standard_empty_companion()
    {
        foreach (var emptyFirst in new[] { false, true })
        {
            var raw = Entry("member;range=0-1", ["CN=A," + Fixtures.Postes, "CN=B," + Fixtures.Postes], emptyFirst);
            var attributes = raw.AttributeNames.ToDictionary(n => n, raw.Raw, StringComparer.OrdinalIgnoreCase);
            attributes.Add("objectClass", new object[] { "top", "group" });
            var fiche = AdFicheObjects.Project(new(Dn, attributes));
            Check.Equal("FALSE", fiche.First("__memberComplete"), "tranche explicitement partielle");
            Check.Equal(2, fiche.All("member").Length, "valeurs utiles conservées malgré le compagnon vide");
        }
    }

    [Test]
    public static async Task Explicit_range_reads_stay_unexpanded_and_cancellation_prevents_a_continuation()
    {
        var raw = Entry("member;range=0-1", ["A", "B"]);
        var result = await AdConnection.MaterializeEntryAsync(raw, Unexpected, None, expand: false);
        Check.True(ReferenceEquals(raw, result), "pas de lecture implicite en mode explicite");
        Check.True(AdAttributeRange.ValueNames(raw, "member").SequenceEqual(new[] { "member;range=0-1" }), "les lecteurs explicites ignorent seulement le compagnon vide");
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => AdConnection.MaterializeEntryAsync(raw, Unexpected, cancel.Token), "annulation avant tout envoi");
    }

    [Test]
    public static void Diagnostic_is_correlated_bounded_and_never_contains_an_AD_value_or_DN()
    {
        var traces = new List<string>();
        void Record(string text) => traces.Add(text);
        AdConnection.TechnicalTrace += Record;
        try
        {
            using var diagnostic = AdReadDiagnostics.Begin("snapshot-groupes");
            AdReadDiagnostics.Sent();
            var first = AdReadDiagnostics.Refuse("objet-modifié", "member", 2, 4, 2, null, true, 2, 2, 5, true, true);
            for (var i = 0; i < 20; i++) { _ = AdReadDiagnostics.Refuse("nom-attribut-refusé", Dn); }
            Check.Equal(16, traces.Count, "journal borné par opération");
            Check.Contains("étape=snapshot-groupes", first.Message, "étape du snapshot");
            Check.Contains("demandé=2-4; reçu=2-*; valeurs=2; cumul=2; limite=5", first.Message, "bornes et nombres sans valeurs");
            Check.Contains("requêtes-envoyées=1; reprise-automatique=0", first.Message, "nombre réel de transmissions");
            Check.True(traces.All(t => !t.Contains(Dn, StringComparison.Ordinal)), "DN refusé jamais recopié comme nom d’attribut");
            var reference = first.Message.Split("op=", StringSplitOptions.None)[1].Split(';')[0];
            Check.True(traces.All(t => t.Contains("op=" + reference, StringComparison.Ordinal)), "même référence pour toute l’opération");
        }
        finally { AdConnection.TechnicalTrace -= Record; }
    }
}
