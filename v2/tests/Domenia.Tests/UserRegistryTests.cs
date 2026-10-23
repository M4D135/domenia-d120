using System.Text;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class UserRegistryTests
{
    private static CimSession Session(Func<string, string, RegistryReply> read, bool enabled = true) => new("PC1.test.local", TimeSpan.FromSeconds(3), TestClock.Fixed())
    { RegistryEnabled = enabled, ReadsEnabled = false, UserRegistryOverride = read };

    [Test]
    public static void Disabled_remote_registry_never_opens_a_key_even_when_CIM_is_disabled()
    {
        using var session = Session((_, _) => throw new InvalidOperationException("Aucune ouverture attendue."), false);
        Check.Equal(SourceStatus.Skipped, session.ReadRemoteRegistryUserIdentity().Access.Status, "option distante respectée");
    }

    [Test]
    public static void Registry_names_are_undated_history_bound_to_the_machine_name_before_and_after()
    {
        var keys = new List<(string Key, string Name)>();
        using var session = Session((key, name) => { keys.Add((key, name)); return new(0, name == "ComputerName" ? "PC1" : @"TEST\alice"); });
        var read = session.ReadRemoteRegistryUserIdentity();
        Check.Equal(SourceStatus.Ok, read.Access.Status, "source indépendante de CIM"); Check.Equal(4, keys.Count, "identité puis deux valeurs puis identité");
        Check.True(keys.All(k => k.Name == "ComputerName" || k.Key == InventoryRegistry.LogonUi), "clés de lecture fermées");
        Check.True(read.Candidates.All(c => c.EvidenceAt is null && c.Sid is null && !c.CurrentConsole), "ni date ni SID ni console inventés");
        Check.Equal(InventoryTransport.RemoteRegistry, read.Access.Transport, "transport RPC distinct");
    }

    [Test]
    public static void A_wrong_or_changed_registry_computer_never_supplies_an_account_candidate()
    {
        foreach (var initial in new[] { false, true })
        {
            var identities = 0; var values = 0;
            using var session = Session((_, name) =>
            {
                if (name == "ComputerName") { return new(0, ++identities == 1 && !initial ? "PC1" : "PC2"); }
                values++; return new(0, @"TEST\alice");
            });
            var result = session.ReadRemoteRegistryUserIdentity(); Check.Equal(0, result.Candidates.Length, "aucune attribution");
            Check.Equal(initial ? 0 : 2, values, "pas de LogonUI avant identité initiale");
        }
    }

    [Test]
    public static void A_registry_authentication_rejection_stops_after_one_value_and_never_reuses_an_earlier_candidate()
    {
        var calls = 0;
        using var session = Session((_, name) => { calls++; return name == "ComputerName" ? new(0, "PC1") : new(1326, null); });
        var result = session.ReadRemoteRegistryUserIdentity();
        Check.True(result.Access.AuthenticationRejected, "rejet d’identité partagé"); Check.Equal(2, calls, "pas de seconde valeur ni contrôle tardif");
        Check.Equal(0, result.Candidates.Length, "aucun candidat publié après rejet"); session.ReadRemoteRegistryUserIdentity(); Check.Equal(2, calls, "pas de deuxième connexion");
    }

    [Test]
    public static void A_refused_registry_value_remains_visible_even_when_the_other_name_was_read()
    {
        using var session = Session((_, name) => name == "ComputerName" ? new(0, "PC1") : name == "LastLoggedOnSAMUser" ? new(0, @"TEST\alice") : new(5, null));
        var result = session.ReadRemoteRegistryUserIdentity();
        Check.Equal(SourceStatus.Refused, result.Access.Status, "droit insuffisant explicitement signalé"); Check.False(result.Access.AuthenticationRejected, "pas de faux mot de passe erroné");
        Check.Equal(1, result.Candidates.Length, "valeur réellement reçue disponible pour validation AD");
    }

    [Test]
    public static void Registry_UTF16_is_bounded_and_does_not_need_a_terminating_null_or_expand_variables()
    {
        foreach (var value in new[] { @"TEST\alice", @"TEST\alice" + '\0', "%USERDOMAIN%\\alice" })
        { Check.Equal(value.TrimEnd('\0'), CimSession.DecodeUserRegistryText(Encoding.Unicode.GetBytes(value)), "texte borné sans expansion"); }
        foreach (var bytes in new[] { new byte[] { 65 }, Encoding.Unicode.GetBytes("alice\0bob"), Encoding.Unicode.GetBytes(new string('x', 321)), new byte[] { 0, 216 } })
        { Check.Throws<InvalidDataException>(() => CimSession.DecodeUserRegistryText(bytes), "UTF-16 ou texte hors contrat"); }
    }

    [Test]
    public static async Task Native_registry_fallback_resolves_the_qualified_AD_account_without_replacing_a_console()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => new WmiWorkstationReader(source.Clock)
        { SessionFactory = (host, budget, token) => new(host, budget, source.Clock, cancellationToken: token)
        {
            ReadOverride = (_, _, _) => [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC1", ["UserName"] = null })],
            RegistryOverride = (_, _) => new(2, null), UserRegistryOverride = (_, name) => new(0, name == "ComputerName" ? "PC1" : @"TEST\alice"),
        } } };
        var result = await reader.DetectLastUserAsync(Fixtures.Computer("PC1").DistinguishedName, null, CancellationToken.None);
        Check.True(result.Verified, "compte résolu exactement");
        var relation = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
        Check.Equal(RelationKind.History, relation.Kind, "LogonUI non promu en console"); Check.Null(relation.When, "date de connexion inconnue");
        Check.Contains("Registre distant", relation.Source, "provenance conservée");
    }
}
