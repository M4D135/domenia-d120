using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdSearchProgressTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static SearchQuery Query() => new(SearchListKind.Search, SearchText.Plan("poste*", SearchTypeFilter.Computers, SearchMatchMode.Prefix),
        SearchTypeFilter.Computers, Fixtures.Postes, true, null, null, new HashSet<string>(), 10);
    private static AdEntry Entry(int n) => AdPosteNetworkTests.Entry(Fixtures.Computer("POSTE" + n) with
    { ObjectGuid = Fixtures.IdOf("progress-poste-" + n), Sid = Fixtures.Domain.DomainSid + "-" + (2000 + n) });

    [Test]
    public static async Task Global_search_accepts_real_progress_beyond_the_old_elapsed_timeout()
    {
        var clock = TestClock.Fixed(); var entries = Enumerable.Range(0, 3).Select(Entry).ToArray();
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q =>
        {
            if (q.SortAttribute is null) return [];
            Check.Equal(TimeSpan.FromSeconds(900), q.Budget, "plafond global envoyé au transport");
            foreach (var entry in entries) { clock.Advance(TimeSpan.FromSeconds(100)); q.EntryReceived!.Invoke(entry); }
            return entries;
        } };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: ldap);
        var page = await new AdSearchReader(source).FindAsync(Query(), None);
        Check.Equal(3, page.Rows.Length, "trois lignes qualifiées en 300 secondes");
        Check.False(page.Interrupted, "la progression réelle conserve le budget");
        Check.False(page.More, "fin reçue");
    }

    [Test]
    public static async Task Idle_search_retains_received_rows_and_reports_incomplete_provenance()
    {
        var clock = TestClock.Fixed();
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q =>
        {
            if (q.SortAttribute is null) return [];
            q.EntryReceived!.Invoke(Entry(1)); clock.Advance(TimeSpan.FromSeconds(120));
            q.EntryReceived.Invoke(Entry(2)); return []; // Progress must refuse this late row.
        } };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: ldap);
        var reader = new AdSearchReader(source); var page = await reader.FindAsync(Query(), None);
        Check.Equal(1, page.Rows.Length, "seule la ligne reçue à temps est gardée");
        Check.True(page.Interrupted, "complétude inconnue"); Check.False(page.More, "pas de continuation automatique"); Check.Null(page.LastKey, "pas de curseur trompeur");
        Check.Contains("120", page.Interruption, "temps réel dans le diagnostic");
        Check.Equal(1, (await reader.LocalRowsAsync([Guid.Parse(page.Rows[0].Id)], None)).Length, "résultat réellement conservé");
    }

    [Test]
    public static async Task Transport_timeout_preserves_only_completed_qualified_rows()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q =>
        {
            if (q.SortAttribute is null) return [];
            q.EntryReceived!.Invoke(Entry(1)); throw new DomeniaOperationException(AdErrors.Timeout, "Transport interrompu");
        } };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap);
        var page = await new AdSearchReader(source).FindAsync(Query(), None);
        Check.Equal(1, page.Rows.Length, "entrée terminée préservée"); Check.True(page.Interrupted, "timeout distinct d’une liste vide complète");
    }

    [Test]
    public static async Task User_cancellation_never_turns_into_a_partial_success()
    {
        using var cancelled = new CancellationTokenSource();
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q =>
        {
            if (q.SortAttribute is null) return [];
            q.EntryReceived!.Invoke(Entry(1)); cancelled.Cancel(); cancelled.Token.ThrowIfCancellationRequested(); return [];
        } };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap);
        await Check.ThrowsAsync<OperationCanceledException>(() => new AdSearchReader(source).FindAsync(Query(), cancelled.Token), "geste annulé reste annulé");
        Check.True(source.CurrentDirectory is null || source.CurrentDirectory.ObjectCount == 0, "pas de publication après annulation");
    }

    [Test]
    public static async Task Partial_service_result_refuses_continuation_and_survey()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q =>
        {
            if (q.SortAttribute is null) return [];
            q.EntryReceived!.Invoke(Entry(1)); throw new DomeniaOperationException(AdErrors.Timeout, "timeout");
        } };
        var clock = TestClock.Fixed();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: ldap);
        await source.ConnectAsync(None); // The service consumes an established session; it never connects implicitly.
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Annuaire de test", null, "test.local", []), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]));
        var service = SearchService.From(context);
        var found = await service.RunAsync("poste*", null, SearchTypeFilter.Computers, 10, SearchMatchMode.Prefix, None);
        Check.True(found.Interrupted, "contrat UI partiel"); Check.False(found.Complete, "aucune complétude fabriquée"); Check.Null(found.Offer, "pas de suggestion fondée sur un faux faible total");
        var more = await Check.ThrowsAsync<DomeniaOperationException>(() => service.MoreAsync(found.ListId, 20, None), "relance explicite requise");
        Check.Equal(SearchErrors.ListComplete, more.Code, "refus de continuation");
        var survey = await Check.ThrowsAsync<DomeniaOperationException>(() => service.SurveyPlanAsync(SurveyMode.Ping, found.ListId, [], SurveyScope.Results, false, None), "aucun relevé de cette liste incomplète");
        Check.Equal(SearchErrors.SurveyRefused, survey.Code, "refus avant préparation");
        var checkedAgain = await service.ReconcileAsync(found.ListId, None);
        Check.True(checkedAgain.Interrupted, "la revérification reste partielle"); Check.Equal(0, checkedAgain.Missing.Length, "les absences inconnues ne deviennent pas manquantes");
    }
    [Test]
    public static async Task Partial_revalidation_cannot_mark_a_previously_seen_object_missing()
    {
        var partial = false;
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q =>
        {
            if (q.SortAttribute is null) return [];
            if (!partial) return [Entry(1), Entry(2)];
            q.EntryReceived!.Invoke(Entry(1)); throw new DomeniaOperationException(AdErrors.Timeout, "timeout");
        } };
        var clock = TestClock.Fixed();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: ldap);
        await source.ConnectAsync(None);
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Annuaire de test", null, "test.local", []), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]));
        var service = SearchService.From(context);
        var found = await service.RunAsync("poste*", null, SearchTypeFilter.Computers, 10, SearchMatchMode.Prefix, None);
        Check.Equal(2, found.Rows.Length, "setup complet : deux identités connues");
        Check.True(found.Complete, "fin initiale réelle");
        partial = true; var guidReads = ldap.Searches.Count(q => q.Filter.Contains("(objectGUID=", StringComparison.Ordinal));
        var checkedAgain = await service.ReconcileAsync(found.ListId, None);
        Check.True(checkedAgain.Interrupted, "la relecture n’a reçu qu’une ligne");
        Check.Equal(1, checkedAgain.Rows.Length, "une seule identité relue");
        Check.Equal(0, checkedAgain.Missing.Length, "la seconde ligne est inconnue, pas manquante");
        Check.Equal(0, checkedAgain.Moved.Length, "aucun déplacement déduit");
        Check.Equal(guidReads, ldap.Searches.Count(q => q.Filter.Contains("(objectGUID=", StringComparison.Ordinal)), "aucune relecture par GUID déclenchée sur une absence non établie");
    }

}
