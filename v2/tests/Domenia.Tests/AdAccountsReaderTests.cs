using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdAccountsReaderTests
{
    [Test]
    public static async Task Account_lists_keep_scope_depth_and_unreadable_states_are_not_enabled_accounts()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.Filter == AdDirectoryMapper.UserFilter ? [Entry("Zed"), Entry("Élodie"), Entry("Unread", uac: false)] : [] };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var list = await new AdAccountsReader(source).ListAsync(Scope(), CancellationToken.None);
        Check.Equal(2, list.Counts.Total, "comptes lisibles seulement");
        Check.True(list.Truncated, "l’état illisible rend la liste incomplète");
        Check.True(list.Note!.Contains("état illisible", StringComparison.Ordinal), "raison distincte de la limite");
        Check.Equal("Élodie", list.Rows[0].Name, "tri français sans accent");
        var request = ldap.Searches.Single(q => q.Filter == AdDirectoryMapper.UserFilter);
        Check.Equal(Fixtures.Postes, request.BaseDn, "OU explicite");
        Check.Equal(AdSearchScope.OneLevel, request.Scope, "profondeur directe");
        Check.Equal(5001, request.SizeLimit, "sentinelle au-delà des 5000 comptes");
        Check.Equal(2, source.CurrentDirectory!.Users.Length, "lecture conservée localement");
    }

    [Test]
    public static async Task Account_domain_root_does_not_launch_a_user_search_and_foreign_entries_are_refused()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdAccountsReader(source);
        var root = await reader.ListAsync(Scope() with { Dn = Fixtures.Root }, CancellationToken.None);
        Check.True(root.TooWide && root.Rows.IsEmpty, "racine refusée sans liste");
        Check.False(ldap.Searches.Any(q => q.Filter == AdDirectoryMapper.UserFilter), "aucun recensement de domaine");
        ldap.SearchAnswer = q => q.Filter == AdDirectoryMapper.UserFilter ? [Entry("Outside", parent: "OU=Other," + Fixtures.Root)] : [];
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ListAsync(Scope(), CancellationToken.None), "réponse hors OU");
    }

    [Test]
    public static async Task Account_details_and_batch_candidates_use_exact_fresh_reads()
    {
        var entry = Entry("Alice");
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.Scope == AdSearchScope.Base && q.BaseDn == entry.DistinguishedName ? [entry] : [] };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdAccountsReader(source);
        var detail = await reader.DetailAsync(entry.DistinguishedName, entry.DistinguishedName, CancellationToken.None);
        Check.False(detail.Actions.Disable.Available, "compte opérateur protégé");
        Check.Null(detail.Identity.Created, "aucune date 0001 inventée");
        var missing = "CN=Absent," + Fixtures.Postes;
        var batch = await reader.CandidatesAsync([missing, entry.DistinguishedName, entry.DistinguishedName], CancellationToken.None);
        Check.Null(batch[0].User, "absence préservée au même rang");
        Check.Equal(batch[1].User!.ObjectGuid, batch[2].User!.ObjectGuid, "doublon laissé aux règles du plan collectif");
        ldap.SearchAnswer = _ => [];
        var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.DetailAsync(entry.DistinguishedName, null, CancellationToken.None), "compte supprimé");
        Check.Equal(AccountsRules.UnknownAccount, failure.Code, "ancien cache jamais présenté comme relecture");
    }

    [Test]
    public static async Task Invalid_batches_and_lockout_windows_are_rejected_before_network()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdAccountsReader(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CandidatesAsync([], CancellationToken.None), "lot vide");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CandidatesAsync(Enumerable.Repeat(Fixtures.Postes, 5001).ToArray(), CancellationToken.None), "lot trop grand");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CandidatesAsync(["invalid"], CancellationToken.None), "DN invalide");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.LockoutEventsAsync(Fixtures.Postes, 721, CancellationToken.None), "fenêtre trop grande");
        Check.Equal(0, ldap.Calls, "aucune connexion");
    }

    [Test]
    public static async Task Lockout_refusals_are_preserved_and_previous_session_results_are_discarded()
    {
        var entry = Entry("Alice");
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.Scope == AdSearchScope.Base ? [entry] : [] };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdAccountsReader(source) { LockoutsOverride = (_, _, _, _) => Task.FromResult(new LockoutEventsRead(LockoutReadState.Refused, "dc.test.local", true, [], false)) };
        var read = await reader.LockoutEventsAsync(entry.DistinguishedName, 24, CancellationToken.None);
        Check.Equal(LockoutReadState.Refused, read.Read.State, "refus de lecture conservé");
        reader = new AdAccountsReader(source)
        {
            LockoutsOverride = (_, _, _, _) => { source.Reset(); return Task.FromResult(new LockoutEventsRead(LockoutReadState.Read, "dc.test.local", true, [], false)); },
        };
        var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.LockoutEventsAsync(entry.DistinguishedName, 24, CancellationToken.None), "ancienne session");
        Check.Equal(AdErrors.NotConnected, failure.Code, "résultat périmé écarté");
    }

    private static AccountsScope Scope() => new(Fixtures.Postes, "Postes", "test.local › Postes", false, AccountsScopeOrigin.Section);

    private static AdEntry Entry(string name, bool uac = true, string? parent = null)
    {
        var sid = new SecurityIdentifier("S-1-5-21-1-2-3-1001");
        var bytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(bytes, 0);
        var values = new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [Fixtures.IdOf("account-" + name).ToByteArray()], ["objectSid"] = [bytes], ["objectClass"] = ["top", "person", "user"],
            ["name"] = [name], ["cn"] = [name], ["sAMAccountName"] = [name], ["uSNChanged"] = ["1"],
        };
        if (uac) { values["userAccountControl"] = ["512"]; }
        return new("CN=" + name + "," + (parent ?? Fixtures.Postes), values);
    }
}
