using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class UserIdentityShellTests
{
    private static object ConsoleRow(string account = @"TEST\alice") => new { Kind = "Console", Account = account, Sid = (string?)null, ProcessId = (uint?)null, CreatedUtc = (string?)null };
    private static object Explorer(uint pid = 42) => new { Kind = "Explorer", Account = @"TEST\alice", Sid = Fixtures.User("alice").Sid,
        ProcessId = pid, CreatedUtc = Fixtures.Now.AddHours(-1).ToString("O") };
    private static string Json(object[] rows, string computer = "PC1", int code = 0, bool partial = false) => JsonSerializer.Serialize(new
    { Format = "Domenia.UserIdentityRead/1", Computer = computer, Code = code, Truncated = partial, Rows = rows });

    [Test]
    public static void WinRM_console_is_dated_as_an_observation_while_Explorer_never_invents_a_logon_time()
    {
        var read = CimSession.ParseUserIdentity(Json([Explorer(), ConsoleRow()]), "PC1.test.local", Fixtures.Now);
        Check.True(read.Candidates[0].CurrentConsole, "console placée en premier"); Check.Equal(Fixtures.Now, read.Candidates[0].EvidenceAt!.Value, "date de lecture de console");
        Check.Null(read.Candidates[0].Sid, "aucun SID du jeton inventé pour UserName");
        var owner = read.Candidates[1]; Check.False(owner.CurrentConsole, "propriétaire Explorer différent de la console");
        Check.Equal(Fixtures.User("alice").Sid, owner.Sid!, "SID du propriétaire conservé"); Check.Null(owner.EvidenceAt, "création du processus différente d’une date de connexion");
    }

    [Test]
    public static void WinRM_user_identity_rejects_foreign_ambiguous_oversized_and_undated_process_payloads()
    {
        var valid = Json([Explorer()]);
        foreach (var json in new[] { Json([Explorer()], "PC2"), Json([ConsoleRow(), ConsoleRow()]), Json([Explorer(), Explorer()]),
            Json(Enumerable.Range(1, 18).Select(i => Explorer((uint)i)).ToArray()), valid.Insert(1, "\"computer\":\"PC2\","),
            valid.Replace(Fixtures.Now.AddHours(-1).ToString("O"), "not-a-date", StringComparison.Ordinal),
            valid.Replace(Fixtures.User("alice").Sid, "S-1-5-18", StringComparison.Ordinal),
            valid.Replace("\"Code\":0", "\"Code\":\"0\"", StringComparison.Ordinal), new string('x', 65_537) })
        { Check.Throws<JsonException>(() => CimSession.ParseUserIdentity(json, "PC1.test.local", Fixtures.Now), "contrat non ambigu"); }
    }

    [Test]
    public static void Disabled_WinRM_or_CIM_never_creates_a_shell_for_last_user_detection()
    {
        foreach (var disabledCim in new[] { false, true })
        {
            using var session = new CimSession("PC1.test.local", TimeSpan.FromSeconds(3), TestClock.Fixed(), transport: disabledCim ? InventoryTransport.WinRm : InventoryTransport.Dcom)
            { ReadsEnabled = !disabledCim, InventoryShellOverride = (_, _) => throw new InvalidOperationException("Aucun shell attendu.") };
            Check.Equal(SourceStatus.Skipped, session.ReadWinRmUserIdentity().Access.Status, "option respectée avant réseau");
        }
    }

    [Test]
    public static void An_unconfirmed_shell_cleanup_keeps_finished_identity_but_marks_it_partial_and_does_not_retry()
    {
        var calls = 0;
        using var session = new CimSession("PC1.test.local", TimeSpan.FromSeconds(3), TestClock.Fixed(), transport: InventoryTransport.WinRm)
        { InventoryShellOverride = (kind, budget) =>
        {
            calls++; Check.Equal(InventoryShellRead.UserIdentity, kind, "seul script admis"); Check.True(budget <= TimeSpan.FromSeconds(3), "budget de méthode borné");
            return new(SourceStatus.Ok, Json([Explorer()]), false, false);
        } };
        var result = session.ReadWinRmUserIdentity();
        Check.Equal(1, calls, "une seule création"); Check.Equal(SourceStatus.Partial, result.Access.Status, "fermeture incertaine");
        Check.Equal(1, result.Candidates.Length, "propriétaire effectivement lu conservé"); Check.Contains("Fermeture", result.Access.Detail, "incertitude affichée");
    }

    [Test]
    public static void A_WinRM_authentication_rejection_is_retained_and_prevents_a_second_shell()
    {
        var calls = 0;
        using var session = new CimSession("PC1.test.local", TimeSpan.FromSeconds(3), TestClock.Fixed(), transport: InventoryTransport.WinRm)
        { InventoryShellOverride = (_, _) => { calls++; return new(SourceStatus.Refused, null, true, true); } };
        Check.True(session.ReadWinRmUserIdentity().Access.AuthenticationRejected, "rejet partagé");
        Check.True(session.ReadWinRmUserIdentity().Access.AuthenticationRejected, "rejet maintenu sans reprise"); Check.Equal(1, calls, "pas de nouvel essai");
    }

    [Test]
    public static async Task WinRM_candidates_follow_exact_AD_resolution_and_keep_console_separate_from_owner_history()
    {
        foreach (var console in new[] { false, true })
        {
            using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
            var original = ldap.SearchAnswer;
            ldap.SearchAnswer = q => q.BaseDn == Fixtures.Root ? [AdRelationDirectoryTests.User(Fixtures.User("alice"))] : original!(q);
            var shellCalls = 0;
            var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => new WmiWorkstationReader(source.Clock, useWinRm: true)
            { SessionFactory = (host, budget, token) => new(host, budget, source.Clock, cancellationToken: token, transport: InventoryTransport.WinRm)
            {
                ReadOverride = (_, _, _) => [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC1", ["UserName"] = null })],
                RegistryOverride = (_, _) => new(2, null),
                InventoryShellOverride = (_, _) => { shellCalls++; return new(SourceStatus.Ok, Json([console ? ConsoleRow() : Explorer()]), false, true); },
            } } };
            var result = await reader.DetectLastUserAsync(Fixtures.Computer("PC1").DistinguishedName, null, CancellationToken.None);
            Check.True(result.Verified, "utilisateur AD confirmé"); Check.Equal(1, shellCalls, "un seul shell d’identité");
            var relation = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
            Check.Equal(console ? RelationKind.Console : RelationKind.History, relation.Kind, "nature de la preuve préservée");
            if (console) { Check.Equal(Fixtures.Now, relation.When!.Value, "console datée à la lecture"); }
            else { Check.Null(relation.When, "aucune date de connexion déduite du processus"); }
        }
    }
}
