using System.Collections.Immutable;
using System.Security.AccessControl;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdFicheReaderTests
{
    private const string UserDn = "CN=Élodie," + Fixtures.People;
    private const string GroupDn = "CN=Support," + Fixtures.Root;

    [Test]
    public static async Task Durable_fiche_previews_indexes_and_pickers_work_without_any_LDAP_call()
    {
        using var folder = new TemporaryFolder();
        var store = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("fiche.db"), Fixtures.Root, TestClock.Fixed()));
        var entry = AdFicheObjects.Project(Entry(UserDn, "user", new() { ["displayName"] = ["Élodie Faure"], ["userPrincipalName"] = ["elodie@test.local"], ["extensionAttribute1"] = ["support"] }));
        await store.SaveFicheAsync(new(entry, Fixtures.Now), CancellationToken.None);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap, localStore: store);
        var reader = new AdFicheReader(source);
        Check.Equal("support", (await reader.PreviewAsync(UserDn, CancellationToken.None))!.Entry.First("extensionAttribute1"), "projection brute conservée");
        Check.Equal(entry.ObjectGuid, (await reader.LocalByIdAsync(entry.ObjectGuid.ToString("B"), CancellationToken.None))!.ObjectGuid, "GUID local");
        Check.Equal(1, (await reader.SearchLocalAsync("elodie", [FicheKind.User], 20, CancellationToken.None)).Length, "accents neutralisés");
        Check.Equal("Élodie Faure", (await reader.IndexAsync([UserDn], CancellationToken.None))[UserDn].Name, "index durable");
        Check.Null(await reader.LocalChildCountAsync(Fixtures.People, CancellationToken.None), "une fiche ne constitue pas un census");
        Check.Equal(0, ldap.Calls, "toutes ces opérations restent locales");
    }

    [Test]
    public static async Task A_fiche_is_not_published_when_its_store_refuses_the_read()
    {
        var cache = new FicheCache { Fail = true };
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.Scope == AdSearchScope.Base && q.BaseDn == UserDn ? [Entry(UserDn, "user", new() { ["allowedAttributes"] = ["description"] })] : [] };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdFicheReader(source);
        await Check.ThrowsAsync<IOException>(() => reader.ReadAsync(UserDn, CancellationToken.None), "stockage refusé");
        Check.Null(await reader.PreviewAsync(UserDn, CancellationToken.None), "aucun résultat temporaire publié comme sauvegardé");
    }

    [Test]
    public static async Task A_GUID_race_does_not_store_the_replacement_object_under_the_old_identity()
    {
        var wanted = Entry(UserDn, "user");
        var replacement = Guid.NewGuid();
        var cache = new FicheCache();
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = q => q.Filter == AdObjectAccess.GuidFilter(wanted.Guid("objectGUID")!.Value) ? [wanted]
                : q.Scope == AdSearchScope.Base ? [Entry(UserDn, "user", new() { ["objectGUID"] = [replacement.ToByteArray()], ["allowedAttributes"] = ["description"] })] : [],
        };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap, localStore: cache);
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdFicheReader(source).ReadByGuidAsync(wanted.Guid("objectGUID")!.Value, CancellationToken.None), "recréation à ce DN");
        Check.Equal(0, cache.Saves, "identité refusée avant stockage");
    }

    [Test]
    public static async Task Group_ranges_count_beyond_the_display_without_claiming_a_capped_list_complete()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = q => q.Scope != AdSearchScope.Base ? [] : [Entry(GroupDn, "group", q.Attributes.Any(a => a.Contains("range=1500-", StringComparison.Ordinal))
                ? new() { ["member;range=1500-*"] = Enumerable.Range(1500, 100).Select(i => (object)("CN=U" + i + "," + Fixtures.People)).ToArray() }
                : new() { ["member;range=0-1499"] = Enumerable.Range(0, 1500).Select(i => (object)("CN=U" + i + "," + Fixtures.People)).ToArray() })],
        };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdFicheReader(source);
        var capped = await reader.MembersAsync(GroupDn, 10, 1500, CancellationToken.None);
        Check.False(capped.Complete, "cap atteint sans marqueur terminal");
        Check.Equal(1500, capped.Total, "nombre réellement compté");
        var full = await reader.MembersAsync(GroupDn, 10, 1600, CancellationToken.None);
        Check.True(full.Complete, "dernière tranche terminée");
        Check.Equal(1600, full.Total, "deux tranches comptées");
        Check.Equal(10, full.Dns.Length, "affichage borné séparément");
        Check.True(ldap.Searches.Where(q => q.Scope == AdSearchScope.Base).All(q => !q.ExpandRanges), "tranches explicites");
    }

    [Test]
    public static async Task Foreign_children_and_member_range_gaps_are_refused()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = q => q.Scope == AdSearchScope.Base ? [Entry(q.BaseDn, q.BaseDn == GroupDn ? "group" : "organizationalUnit", q.BaseDn == GroupDn ? new() { ["member;range=1-*"] = [UserDn] } : null)]
                : q.Scope == AdSearchScope.OneLevel ? [Entry("CN=Outside,OU=Other," + Fixtures.Root, "user")] : [],
        };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdFicheReader(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ChildrenAsync(Fixtures.People, 100, CancellationToken.None), "enfant étranger");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.MembersAsync(GroupDn, 10, 50, CancellationToken.None), "début de tranche absent");
    }

    [Test]
    public static async Task Group_graph_cycles_end_and_unread_branches_remain_unknown()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = q => q.Scope != AdSearchScope.Base ? [] : q.BaseDn == UserDn ? [Entry(UserDn, "user", new() { ["memberOf"] = [GroupDn] })]
                : q.BaseDn == GroupDn ? [Entry(GroupDn, "group", new() { ["memberOf"] = [GroupDn, "CN=Foreign,DC=other,DC=local"] })] : [],
        };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var graph = await new AdFicheReader(source).GroupGraphAsync(UserDn, CancellationToken.None);
        Check.Equal(1, graph.Nodes.Count, "cycle visité une seule fois");
        Check.Equal(1, graph.Unread, "groupe étranger inconnu");
        Check.False(ldap.Searches.Any(q => q.BaseDn.Contains("DC=other", StringComparison.Ordinal)), "aucune lecture hors domaine");
    }

    [Test]
    public static async Task Password_policy_reads_actual_values_without_defaults_and_refuses_foreign_PSOs()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = q => q.Scope != AdSearchScope.Base ? [] : q.BaseDn == UserDn ? [Entry(UserDn, "user")]
                : [Entry(Fixtures.Root, "domainDNS", new() { ["maxPwdAge"] = [(-TimeSpan.FromDays(42).Ticks).ToString(System.Globalization.CultureInfo.InvariantCulture)], ["pwdProperties"] = ["0"], ["lockoutDuration"] = ["0"] })],
        };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdFicheReader(source);
        var policy = await reader.PasswordPolicyAsync(UserDn, CancellationToken.None);
        Check.Equal(TimeSpan.FromDays(42), policy.MaxAge!.Value, "intervalle LDAP négatif");
        Check.Null(policy.MinLength, "valeur absente non remplacée par zéro");
        Check.Equal(false, policy.Complexity!.Value, "bit de complexité désactivé");
        Check.True(policy.LockoutNever, "déverrouillage administratif si durée nulle");
        ldap.SearchAnswer = q => q.Scope == AdSearchScope.Base ? [Entry(UserDn, "user", new() { ["msDS-ResultantPSO"] = ["CN=Policy,DC=other,DC=local"] })] : [];
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.PasswordPolicyAsync(UserDn, CancellationToken.None), "PSO étranger");
        Check.False(ldap.Searches.Any(q => q.BaseDn.Contains("DC=other", StringComparison.Ordinal)), "PSO jamais contacté");
    }

    [Test]
    public static void Security_estimate_does_not_expand_attribute_specific_aces_to_all_properties()
    {
        const string sid = "S-1-5-21-1-2-3-1001";
        var descriptor = new RawSecurityDescriptor("O:SYG:SYD:(OA;;WP;11111111-1111-1111-1111-111111111111;;" + sid + ")(OA;;CR;00299570-246d-11d0-a768-00aa006e0529;;" + sid + ")(A;;RP;;;S-1-1-0)");
        var bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0);
        var reading = AdFicheReader.ParseSecurity(bytes, new HashSet<string> { sid, "S-1-1-0" }, null, Fixtures.Now);
        Check.True(reading.Available, "DACL interprétable");
        Check.False(reading.Aces.Any(a => (a.Rights & 0x20) != 0), "pas d’écriture générale déduite");
        Check.True(reading.Aces.Any(a => a.ResetPassword), "droit étendu précis conservé");
        Check.True(reading.Aces.Any(a => (a.Rights & 0x10) != 0), "lecture non limitée conservée");
    }

    [Test]
    public static void Replication_history_rejects_external_entities_and_hides_sensitive_attribute_names()
    {
        string Xml(string name) => "<DS_REPL_ATTR_META_DATA><pszAttributeName>" + name + "</pszAttributeName><dwVersion>2</dwVersion><ftimeLastOriginatingChange>2026-10-21T10:00:00Z</ftimeLastOriginatingChange><pszLastOriginatingDsaDN>CN=NTDS Settings,CN=DC1,CN=Servers,CN=Paris,CN=Sites,CN=Configuration," + Fixtures.Root + "</pszLastOriginatingDsaDN></DS_REPL_ATTR_META_DATA>";
        var history = AdFicheReader.ParseHistory([Xml("description"), Xml("unicodePwd")]);
        Check.Equal(1, history.Length, "aucune métadonnée de secret");
        Check.Equal("DC1", history[0].Controller, "origine extraite du DN");
        Check.Throws<DomeniaOperationException>(() => AdFicheReader.ParseHistory(["<!DOCTYPE x [<!ENTITY ext SYSTEM 'file:///forbidden'>]><DS_REPL_ATTR_META_DATA>&ext;</DS_REPL_ATTR_META_DATA>"]), "DTD refusée");
        Check.Throws<DomeniaOperationException>(() => AdFicheReader.ParseHistory([Xml("description").Replace("<dwVersion>2</dwVersion>", "<dwVersion>2</dwVersion><dwVersion>3</dwVersion>", StringComparison.Ordinal)]), "champ ambigu refusé");
    }

    [Test]
    public static void WTS_clocks_and_protocol_use_the_documented_Windows_fields()
    {
        Check.Equal(16, WindowsSessionsReader.ProtocolClass, "WTSClientProtocolType après WTSClientDisplay");
        Check.Equal("RDP", WindowsSessionsReader.Protocol([2, 0]), "USHORT protocole RDP");
        Check.Equal("Non lu", WindowsSessionsReader.Protocol([2]), "tampon court refusé");
        var info = new byte[216];
        BitConverter.GetBytes(3).CopyTo(info, 4);
        BitConverter.GetBytes(Fixtures.Ft(Fixtures.Now.AddMinutes(-5))).CopyTo(info, 192);
        BitConverter.GetBytes(Fixtures.Ft(Fixtures.Now.AddHours(-1))).CopyTo(info, 200);
        BitConverter.GetBytes(Fixtures.Ft(Fixtures.Now)).CopyTo(info, 208);
        var clocks = WindowsSessionsReader.Clocks(info, 3);
        Check.Equal(Fixtures.Now.AddHours(-1), clocks.Logon!.Value, "heure de session");
        Check.Equal(TimeSpan.FromMinutes(5), clocks.Idle!.Value, "écart des horloges du même poste");
        Check.Null(WindowsSessionsReader.Clocks(info, 4).Logon, "autre session refusée");
    }

    [Test]
    public static void Real_DACL_order_preserves_an_explicit_allow_before_an_inherited_deny()
    {
        var read = new FicheSecurityReading(true, null, "Owner", 1, [new(false, "User", 0x20, false, null), new(true, "Group", 0x20, false, "Parent")], Fixtures.Now) { InDirectoryOrder = true };
        Check.Equal("allowed", FicheDiagnostics.Rights(read, TestClock.Paris).Rows.Single(r => r.Id == "edit").State, "première ACE applicable");
        read = read with { Aces = [.. read.Aces.Reverse()] };
        Check.Equal("denied", FicheDiagnostics.Rights(read, TestClock.Paris).Rows.Single(r => r.Id == "edit").State, "refus rencontré avant accord");
    }

    [Test]
    public static async Task A_newer_local_move_supersedes_an_old_raw_fiche_and_its_index()
    {
        var old = AdFicheObjects.Project(Entry(UserDn, "user"));
        var newer = Fixtures.User("elodie") with { ObjectGuid = old.ObjectGuid, DistinguishedName = "CN=Élodie,OU=Moved," + Fixtures.Root };
        var cache = new FicheCache
        {
            Directory = new(Fixtures.Domain, Fixtures.Now.AddMinutes(1), false, [], [newer], [], []),
            Stored = new(old, Fixtures.Now),
        };
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(Fixtures.Now.AddMinutes(1)), connection: ldap, localStore: cache);
        var reader = new AdFicheReader(source);
        Check.Null(await reader.PreviewAsync(UserDn, CancellationToken.None), "ancien emplacement non ressuscité");
        Check.Equal(newer.DistinguishedName, (await reader.LocalByIdAsync(old.ObjectGuid.ToString(), CancellationToken.None))!.Dn, "GUID pointe vers le relevé le plus récent");
        Check.Equal(0, ldap.Calls, "arbitrage seulement local");
    }

    [Test]
    public static void Partial_memberships_never_invent_removals_and_session_refusals_never_claim_absence()
    {
        var session = new FicheSession();
        var full = AdFicheObjects.Project(Entry(UserDn, "user", new() { ["memberOf"] = [GroupDn, "CN=Other," + Fixtures.Root] }));
        session.Observe(full, Fixtures.Now);
        var partial = full.With(new Dictionary<string, ImmutableArray<string>> { ["memberOf"] = [GroupDn], ["__memberOfComplete"] = ["FALSE"] });
        var baseline = session.Observe(partial, Fixtures.Now.AddMinutes(1));
        Check.Equal(0, baseline!.Changes.Length, "aucun groupe retiré sur lecture partielle");
        var refused = new FicheSessionsReading("CN=PC," + Fixtures.Postes, "PC", "refused", [], 0, Fixtures.Now, "Accès refusé");
        Check.Equal("refused", FicheCallSheets.SessionSummary(refused, "TEST\\elodie").State, "aucune absence de session déduite");
        var read = refused with { State = "read", Error = null, Rows = [new("TEST\\elodie", "Active", "Console", null, null), new("PC\\elodie", "Active", "RDP", null, null)] };
        Check.Equal(1, FicheCallSheets.SessionSummary(read, "TEST\\elodie").Mine, "homonyme local distinct du compte domaine");
    }

    internal static AdEntry Entry(string dn, string kind, Dictionary<string, IReadOnlyList<object>>? extra = null)
    {
        var values = new Dictionary<string, IReadOnlyList<object>>(StringComparer.OrdinalIgnoreCase)
        {
            ["objectGUID"] = [Fixtures.IdOf(dn).ToByteArray()], ["objectClass"] = ["top", kind], ["name"] = [FicheValues.DisplayName(dn)], ["uSNChanged"] = ["1"],
        };
        if (kind == "group") { values["groupType"] = ["-2147483646"]; }
        if (extra is not null) { foreach (var pair in extra) { values[pair.Key] = pair.Value; } }
        return new(dn, values);
    }

    private sealed class FicheCache : IDirectoryCache, IFicheCache
    {
        public bool Fail { get; init; }
        public DirectorySnapshot? Directory { get; init; }
        public FicheLocalRead? Stored { get; init; }
        public int Saves { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Task.FromResult(Directory);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<FicheLocalRead?> ReadFicheAsync(string dn, CancellationToken cancellationToken) => Task.FromResult(Stored is { } item && FicheValues.SameDn(item.Entry.Dn, dn) ? item : null);
        public Task<ImmutableArray<FicheSummary>> ReadFicheIndexAsync(CancellationToken cancellationToken) => Task.FromResult<ImmutableArray<FicheSummary>>(Stored is { } item ? [FicheSummary.From(item.Entry, item.ReadAt)] : []);
        public Task<FicheLocalRead> SaveFicheAsync(FicheLocalRead fiche, CancellationToken cancellationToken) { Saves++; return Fail ? throw new IOException("stockage refusé") : Task.FromResult(fiche); }
    }
}
