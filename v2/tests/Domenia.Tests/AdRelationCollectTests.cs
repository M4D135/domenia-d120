using System.ComponentModel;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationCollectTests
{
    private static readonly DirectoryUser Alice = Fixtures.User("alice");
    private static RelationDetectionRequest Request => new(Alice.DistinguishedName, Alice.ObjectGuid, Alice.SamAccountName, "candidates", null, [], 20, false);
    private static AdEntry Fields(AdEntry entry, params (string Name, object Value)[] extra)
    {
        var fields = entry.AttributeNames.ToDictionary(n => n, entry.Raw, StringComparer.OrdinalIgnoreCase);
        foreach (var (name, value) in extra) { fields[name] = [value]; }
        return new(entry.DistinguishedName, fields);
    }
    private static AdEntry Pc(string name, bool managed = true, bool mentioned = true) => Fields(AdPosteNetworkTests.Entry(Fixtures.Computer(name)),
        ("managedBy", managed ? Alice.DistinguishedName : ""), ("description", mentioned ? "Poste de alice" : ""));
    private static bool Subject(AdSearchRequest q) => DistinguishedName.AreEqual(q.BaseDn, Alice.DistinguishedName);
    private static bool Managed(AdSearchRequest q) => q.Filter.Contains("managedBy=", StringComparison.Ordinal);
    private static bool Mentioned(AdSearchRequest q) => q.Filter.Contains("(description=*", StringComparison.Ordinal);

    [Test]
    public static async Task Collection_rechecks_the_selected_GUID_and_login_before_reading_other_sources()
    {
        foreach (var changed in new[] { Alice with { ObjectGuid = Fixtures.IdOf("replacement") }, Alice with { SamAccountName = "renamed" } })
        {
            using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
            ldap.SearchAnswer = _ => [AdRelationDirectoryTests.User(changed)];
            await Check.ThrowsAsync<DomeniaOperationException>(() => new AdRelationsReader(source).CollectAsync(Request, CancellationToken.None), "identité changée");
            Check.Equal(1, ldap.Searches.Count, "une seule relecture du sujet, pas d’autre source");
        }
    }

    [Test]
    public static async Task Collection_merges_current_AD_clues_by_GUID_without_reading_a_console_or_writing_relations()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var disabled = Fields(Pc("PC2"), ("userAccountControl", 4098)); var controller = Fields(Pc("DC1"), ("userAccountControl", 8192));
        ldap.SearchAnswer = q => Subject(q) ? [AdRelationDirectoryTests.User(Alice)] : Managed(q) ? [Pc("PC1"), disabled, controller] : Mentioned(q) ? [Pc("PC1")] : [];
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => throw new InvalidOperationException("Aucune console pendant la collecte.") };
        var result = await reader.CollectAsync(Request, CancellationToken.None);
        Check.Equal(1, result.Candidates.Length, "un seul GUID après fusion et exclusions"); Check.Contains("Responsable déclaré", result.Candidates[0].Origins, "premier indice");
        Check.Contains("Mention du compte", result.Candidates[0].Origins, "second indice"); Check.False(result.Candidates[0].Confirmed, "indice non confirmé");
        Check.Equal(0, result.Savable, "aucune observation inventée"); Check.True(result.Plan!.Allowed, "périmètre exact préparé");
        var held = AdRelationResults.For(source).Recall<AdRelationProbePlan>(result.Plan.Id!, source.Epoch);
        Check.Equal("pc1.test.local", held.Hosts.Single().Value, "DNS exact détenu par le moteur"); Check.Equal(Alice.ObjectGuid, held.Subject!.Guid, "sujet lié au plan");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucune relation écrite");
        Check.True(ldap.Searches.Where(q => q.Scope == AdSearchScope.Subtree).All(q => q.PageSize == 40 && q.SizeLimit == 101), "lectures d’indices bornées");
        Check.Equal(1, source.CurrentDirectory!.Computers.Length, "index existant non remplacé par des lectures partielles");
    }

    [Test]
    public static async Task Collection_preserves_the_loaded_perimeter_and_rejects_domain_or_foreign_OUs_before_network()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        foreach (var dn in new[] { Fixtures.Root, "CN=Computers," + Fixtures.Root, "OU=Other,DC=foreign,DC=local" })
        { await Check.ThrowsAsync<DomeniaOperationException>(() => new AdRelationsReader(source).CollectAsync(Request with { Scope = "ou", OuDn = dn }, CancellationToken.None), "portée non autorisée"); }
        Check.Equal(0, ldap.Searches.Count, "pas de contact pour une portée invalide");
        ldap.SearchAnswer = q => Subject(q) ? [AdRelationDirectoryTests.User(Alice)] : Managed(q) ? [Pc("PC2")] : Mentioned(q) ? [] : [Pc("PC1")];
        var result = await new AdRelationsReader(source).CollectAsync(Request with { Scope = "loaded", OuDn = Fixtures.Root, Computers = ["PC1", @"FOREIGN\PC2", "unknown", "PC1"] }, CancellationToken.None);
        Check.Equal("PC1", result.Plan!.Targets.Single().Computer, "liste chargée sans substitution par les candidats AD");
        Check.Equal("PC2", result.Candidates.Single().Computer, "indice extérieur visible mais non sondé"); Check.Null(result.Plan.OuDn, "OU ignorée en mode liste");
        Check.True(ldap.Searches.Any(q => q.Filter.Contains(AdObjectAccess.GuidFilter(Fixtures.Computer("PC1").ObjectGuid), StringComparison.Ordinal)), "identité chargée relue par GUID");
    }

    [Test]
    public static async Task Collection_excludes_every_version_of_a_conflicting_GUID_or_DN_across_sources()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var changedHost = Fields(Pc("PC1"), ("dNSHostName", "pc1.changed.test.local"));
        ldap.SearchAnswer = q => Subject(q) ? [AdRelationDirectoryTests.User(Alice)] : Managed(q) ? [Pc("PC1")] : Mentioned(q) ? [changedHost] : [];
        var result = await new AdRelationsReader(source).CollectAsync(Request, CancellationToken.None);
        Check.Equal(0, result.Candidates.Length, "GUID de versions contradictoires entièrement écarté"); Check.False(result.Plan!.Allowed, "aucun DNS choisi arbitrairement"); Check.True(result.Partial, "conflit annoncé");
        var replacement = Fields(Pc("PC1"), ("objectGUID", Fixtures.IdOf("different-at-same-dn").ToByteArray()));
        ldap.SearchAnswer = q => Subject(q) ? [AdRelationDirectoryTests.User(Alice)] : Managed(q) ? [Pc("PC1")] : Mentioned(q) ? [replacement] : [];
        result = await new AdRelationsReader(source).CollectAsync(Request, CancellationToken.None);
        Check.Equal(0, result.Candidates.Length, "DN changeant de GUID entièrement écarté"); Check.False(result.Plan!.Allowed, "pas de poste substitué");
    }

    [Test]
    public static async Task Kerberos_collection_reads_only_the_selected_SID_and_keeps_addresses_as_hints_without_reverse_DNS()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        ldap.SearchAnswer = q => Subject(q) ? [AdRelationDirectoryTests.User(Alice)] : [];
        var calls = 0;
        var reader = new AdRelationsReader(source) { EventReaderOverride = clock => new(clock)
        {
            ReadOverride = (request, query, credential, _) =>
            {
                calls++; Check.Equal(Alice.Sid, request.SubjectSid!, "SID du compte relu"); Check.Equal(100, request.Maximum, "plafond ciblé");
                Check.Equal(TimeSpan.FromDays(7), request.To - request.From, "fenêtre de sept jours"); Check.True(credential!.Session, "identité du bail LDAP");
                Check.False(query.Contains("4769", StringComparison.Ordinal), "pas de ticket service");
                return Enumerable.Range(1, 2).Select(i => new RelationLogRaw(i, 4768, Fixtures.Now.AddHours(-i), "alice", "Security", "DC1.test.local", []))
                    .Select(r => r with { Provider = "Microsoft-Windows-Security-Auditing", Values = ["alice", "TEST", Alice.Sid, null, "10.77.0.5", null, null, "0x0"] });
            },
        } };
        var result = await reader.CollectAsync(Request with { Kerberos = true }, CancellationToken.None);
        Check.Equal(1, calls, "un seul contrôleur"); Check.Equal(1, result.Hints.Length, "adresse dédupliquée"); Check.Equal(Fixtures.Now.AddHours(-1), result.Hints[0].ObservedAt!.Value, "date historique récente");
        Check.Equal(0, result.Candidates.Length, "IP jamais convertie en ordinateur"); Check.False(result.Plan!.Allowed, "aucun poste à contacter à partir d’une IP seule");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucune association automatique");
    }

    [Test]
    public static async Task Collection_keeps_finished_clues_after_refusal_or_timeout_but_never_exposes_a_probe_plan()
    {
        foreach (var journalFailure in new[] { false, true })
        {
            using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
            ldap.SearchAnswer = q => Subject(q) ? [AdRelationDirectoryTests.User(Alice)] : Managed(q) ? [Pc("PC1")]
                : journalFailure ? [] : throw new DomeniaOperationException(AdErrors.Timeout, "Erreur simulée");
            var reader = new AdRelationsReader(source) { EventReaderOverride = clock => new(clock)
            { ReadOverride = (_, _, _, _) => throw new Win32Exception(1326) } };
            var result = await reader.CollectAsync(Request with { Kerberos = journalFailure }, CancellationToken.None);
            Check.Equal(1, result.Candidates.Length, "indice terminé conservé"); Check.True(result.Partial, "lecture incomplète"); Check.False(result.Plan!.Allowed, "aucun plan après refus ou délai");
            Check.True(result.Attempts.Any(a => a.Status == (journalFailure ? "AUTH_REJETEE" : "A_REVOIR")), "raison visible");
            Check.Equal(1, ldap.Searches.Count(Subject), "pas de relecture après le refus ou le délai");
        }
    }

    [Test]
    public static async Task Collection_never_reassigns_a_missing_historical_GUID_to_a_same_named_computer()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var old = Fixtures.IdOf("old-computer");
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,user_guid,computer_guid) VALUES('legacy','alice','PC1','Saisie manuelle',?1,?2);", Alice.ObjectGuid.ToString("D"), old.ToString("D")); }
        ldap.SearchAnswer = q => Subject(q) ? [AdRelationDirectoryTests.User(Alice)] : Managed(q) || Mentioned(q) ? [] : [Pc("PC1")];
        var result = await new AdRelationsReader(source).CollectAsync(Request, CancellationToken.None);
        Check.False(result.Plan!.Allowed, "homonyme sans le GUID attendu exclu"); Check.Equal(0, result.Candidates.Length, "aucun candidat substitué");
        Check.True(ldap.Searches.Any(q => q.Filter.Contains(AdObjectAccess.GuidFilter(old), StringComparison.Ordinal)), "GUID historique exact demandé");
        Check.Equal(old, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation.ComputerGuid!.Value, "historique conservé");
    }

    [Test]
    public static async Task Collection_limits_each_source_and_invalidates_a_subject_changed_at_the_end()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var many = Enumerable.Range(1, 101).Select(i => Pc("PC" + i)).ToArray();
        ldap.SearchAnswer = q => Subject(q) ? [AdRelationDirectoryTests.User(Alice)] : Managed(q) ? many : [];
        var result = await new AdRelationsReader(source).CollectAsync(Request with { Limit = 50 }, CancellationToken.None);
        Check.Equal(100, result.Candidates.Length, "sentinelle non affichée"); Check.Equal(50, result.Plan!.Targets.Length, "cinquante cibles maximum");
        Check.True(result.Partial && result.Plan.Truncated, "deux limites signalées");
        var subjects = 0;
        ldap.SearchAnswer = q => Subject(q) ? [AdRelationDirectoryTests.User(++subjects == 1 ? Alice : Alice with { SamAccountName = "changed" })] : Managed(q) ? [Pc("PC1")] : [];
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdRelationsReader(source).CollectAsync(Request, CancellationToken.None), "identité modifiée avant publication");
        Check.Equal(2, subjects, "compte recontrôlé après la collecte");
    }
}
