using System.Collections.Immutable;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Native audit contracts, with an in-memory LDAP transport; no domain, DNS or workstation is contacted.</summary>
internal static class AdAuditReaderTests
{
    [Test]
    public static void RootDse_missing_and_invalid_health_attributes_remain_unknown()
    {
        foreach (var attributes in new Dictionary<string, IReadOnlyList<object>>[]
        {
            [], new() { ["isSynchronized"] = ["maybe"], ["highestCommittedUSN"] = ["-1"] },
        })
        {
            var root = AdConnection.MapRootDse(new AdEntry("", attributes));
            Check.Null(root.IsSynchronized, "synchronisation inconnue");
            Check.Null(root.HighestCommittedUsn, "USN inconnu");
        }
        var known = AdConnection.MapRootDse(new AdEntry("", new Dictionary<string, IReadOnlyList<object>>
        { ["isSynchronized"] = ["FALSE"], ["highestCommittedUSN"] = ["0"] }));
        Check.Equal<bool?>(false, known.IsSynchronized, "faux explicite conservé");
        Check.Equal<long?>(0, known.HighestCommittedUsn, "zéro explicite conservé");
    }

    [Test]
    public static void Controller_health_never_turns_unread_replication_or_time_into_green()
    {
        var at = TestClock.Fixed().GetUtcNow();
        var complete = new ControllerProbeRead("dc1.test.local", ["192.0.2.1"], null, true, true, ReadState.Read, null,
            at, at, true, 100, ReadState.Read, null,
            [new(Fixtures.Root, "dc2", at, at, 0, 0, false)]);
        var readings = new[]
        {
            complete with { CurrentTime = null }, complete with { IsSynchronized = null },
            complete with { Replication = ReadState.Refused, Neighbors = [] },
            complete with { Replication = ReadState.NotRead, Neighbors = [] },
            complete with { Kerberos = null },
        };
        foreach (var reading in readings)
        {
            var view = AuditControllerRules.HealthView(new([reading], [reading.Controller], ReadState.Read, null, null, at), at, TimeZoneInfo.Utc);
            Check.Equal(ControllerVerdict.NotRead, view.Rows.Single().Verdict, "aucun faux sain");
        }
        var healthy = AuditControllerRules.HealthView(new([complete], [complete.Controller], ReadState.Read, null, null, at), at, TimeZoneInfo.Utc);
        Check.Equal(ControllerVerdict.Clear, healthy.Rows.Single().Verdict, "données complètes sans écart");
    }

    [Test]
    public static async Task Audit_local_entry_points_do_not_contact_LDAP()
    {
        using var f = await Fixture.Create(); var calls = f.Connection.Calls;
        await f.Reader.SearchObjectsAsync("", 10, CancellationToken.None);
        await f.Reader.FindTargetAsync(Fixtures.Root, CancellationToken.None);
        await f.Reader.FindDomainGroupAsync(512, CancellationToken.None);
        await f.Reader.LocalTotalsAsync(CancellationToken.None);
        Check.Equal(calls, f.Connection.Calls, "aucune lecture réseau implicite");
    }

    [Test]
    public static async Task Identity_scan_refuses_domain_subtree_before_any_search()
    {
        using var f = await Fixture.Create(); var calls = f.Connection.Calls;
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => f.Reader.IdentityScanAsync(Fixtures.Root, true, 100, CancellationToken.None), "domaine entier");
        Check.Equal(AuditErrors.ScopeTooWide, error.Code, "portée refusée");
        Check.Equal(calls, f.Connection.Calls, "pas de requête");
    }

    [Test]
    public static async Task Identity_scan_rejects_duplicates_and_objects_outside_requested_scope()
    {
        foreach (var duplicate in new[] { true, false })
        {
            using var f = await Fixture.Create();
            var user = Entry("CN=Alice," + (duplicate ? Fixtures.People : Fixtures.Postes), "user", Fixtures.IdOf("alice"));
            f.Connection.SearchAnswer = request => request.Scope == AdSearchScope.Base
                ? [Entry(Fixtures.People, "organizationalUnit", Fixtures.IdOf("people"))] : duplicate ? [user, user] : [user];
            await Check.ThrowsAsync<DomeniaOperationException>(() => f.Reader.IdentityScanAsync(Fixtures.People, true, 100, CancellationToken.None), "identité ou portée invalide");
        }
    }

    [Test]
    public static async Task Identity_scan_keeps_limit_and_sentinel_without_claiming_complete()
    {
        using var f = await Fixture.Create();
        f.Connection.SearchAnswer = request => request.Scope == AdSearchScope.Base
            ? [Entry(Fixtures.People, "organizationalUnit", Fixtures.IdOf("people"))]
            : [Entry("CN=Alice," + Fixtures.People, "user", Fixtures.IdOf("alice")), Entry("CN=Bob," + Fixtures.People, "user", Fixtures.IdOf("bob"))];
        var result = await f.Reader.IdentityScanAsync(Fixtures.People, false, 1, CancellationToken.None);
        Check.True(result.Truncated, "sentinelle conservée");
        Check.Equal(1, result.Objects.Length, "plafond");
        var search = f.Connection.Searches.Last();
        Check.Equal(AdSearchScope.OneLevel, search.Scope, "profondeur choisie");
        Check.Equal(2, search.SizeLimit, "une sentinelle");
        Check.True(search.Budget <= TimeSpan.FromSeconds(30), "budget borné");
    }

    [Test]
    public static async Task Password_policy_discards_recreated_object_at_same_DN()
    {
        using var f = await Fixture.Create(); var target = User();
        f.Connection.SearchAnswer = _ => [Entry(target.Dn, "user", Guid.NewGuid())];
        await Check.ThrowsAsync<DomeniaOperationException>(() => f.Reader.PasswordPolicyAsync(target, CancellationToken.None), "GUID différent");
        Check.Equal(1, f.Connection.Searches.Count, "aucune stratégie lue après substitution");
    }

    [Test]
    public static async Task Missing_GPO_options_are_unread_never_no_inheritance_block()
    {
        using var f = await Fixture.Create();
        f.Connection.SearchAnswer = _ => [Entry(Fixtures.People, "organizationalUnit", Fixtures.IdOf("people"))];
        var read = await f.Reader.GpoLinksAsync([Fixtures.People], CancellationToken.None);
        Check.Equal(ReadState.Unavailable, read.Containers.Single().State, "option absente non supposée");
        Check.Equal(ReadState.Unavailable, read.NamesState, "lecture incomplète visible");
    }

    [Test]
    public static async Task Missing_ACL_and_tokenGroups_stay_unknown()
    {
        using var f = await Fixture.Create(); var target = User();
        f.Connection.SearchAnswer = _ => [Entry(target.Dn, "user", target.ObjectGuid!.Value, target.Sid)];
        var acl = await f.Reader.DelegationsAsync(target, CancellationToken.None);
        Check.Equal(ReadState.Unavailable, acl.State, "DACL absente non vide");
        Check.Equal(-1, acl.Total, "nombre inconnu");
        var token = await f.Reader.TokenGroupsAsync(target.Sid!, CancellationToken.None);
        Check.Equal(ReadState.NotRead, token.State, "tokenGroups absent non vide");
    }

    [Test]
    public static async Task Domain_refusal_stops_all_following_security_reads()
    {
        using var f = await Fixture.Create();
        f.Connection.SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.AccessDenied, AdErrors.AccessDeniedMessage);
        var read = await f.Reader.DomainOverviewAsync(CancellationToken.None);
        Check.Equal(1, f.Connection.Searches.Count, "pas de rafale après refus");
        Check.True(read.Checks.All(c => c.State == ReadState.NotRead), "aucun contrôle sain inventé");
    }

    [Test]
    public static async Task Unknown_controller_cannot_reach_the_comparison_transport()
    {
        using var f = await Fixture.Create(); var factories = 0;
        var reader = new AdAuditReader(f.Source) { ControllerFactory = (_, _) => { factories++; return f.Connection; } };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CompareObjectAsync(User(), ["evil.foreign.local"], CancellationToken.None), "contrôleur non listé");
        Check.Equal(0, factories, "aucune connexion au nom fourni");
    }

    [Test]
    public static async Task Membership_rejects_result_for_other_DN_even_if_GUID_matches()
    {
        using var f = await Fixture.Create(); var target = User(); var group = "CN=G," + Fixtures.Root;
        f.Connection.SearchAnswer = r => r.Filter.Contains("1.2.840.113556.1.4.1941", StringComparison.Ordinal)
            ? [Entry("CN=Other," + Fixtures.People, "user", target.ObjectGuid!.Value, target.Sid)]
            : [Entry(r.BaseDn, r.BaseDn == group ? "group" : "user", r.BaseDn == group ? Fixtures.IdOf("G") : target.ObjectGuid!.Value, r.BaseDn == group ? null : target.Sid)];
        var read = await f.Reader.MembershipAsync(target, group, CancellationToken.None);
        Check.Null(read.Member, "résultat hors identité écarté");
    }

    [Test]
    public static void Replication_metadata_rejects_duplicate_fields_and_negative_counters()
    {
        foreach (var fragment in new[]
        {
            "<OTHER><pszAttributeName>name</pszAttributeName><dwVersion>1</dwVersion><usnLocalChange>1</usnLocalChange><usnOriginatingChange>1</usnOriginatingChange></OTHER>",
            "<DS_REPL_ATTR_META_DATA><pszAttributeName>name</pszAttributeName><dwVersion>-1</dwVersion><usnLocalChange>1</usnLocalChange><usnOriginatingChange>1</usnOriginatingChange></DS_REPL_ATTR_META_DATA>",
            "<DS_REPL_ATTR_META_DATA><pszAttributeName>name</pszAttributeName><pszAttributeName>mail</pszAttributeName><dwVersion>1</dwVersion><usnLocalChange>1</usnLocalChange><usnOriginatingChange>1</usnOriginatingChange></DS_REPL_ATTR_META_DATA>",
        })
        {
            Check.Throws<DomeniaOperationException>(() => AdAuditReader.ParseMetadata([fragment]), "fragment incohérent");
        }
        var read = AdAuditReader.ParseMetadata(["<DS_REPL_ATTR_META_DATA><pszAttributeName>name</pszAttributeName><dwVersion>1</dwVersion><usnLocalChange>42</usnLocalChange><usnOriginatingChange>7</usnOriginatingChange></DS_REPL_ATTR_META_DATA>"]);
        Check.Equal(42L, read.Single().LocalUsn, "USN local conservé sans comparaison inter-contrôleurs");
    }

    private static AuditTarget User() => new("CN=Alice," + Fixtures.People, AuditObjectKind.User, "Alice", "alice", Fixtures.IdOf("alice"), Fixtures.Domain.DomainSid + "-1001", null, 513, null);
    private static AdEntry Entry(string dn, string kind, Guid id, string? sid = null)
    {
        var attributes = new Dictionary<string, IReadOnlyList<object>>
        { ["objectGUID"] = [id.ToByteArray()], ["objectClass"] = [kind], ["name"] = ["Objet"], ["userAccountControl"] = ["512"] };
        if (sid is not null)
        {
            var identity = new SecurityIdentifier(sid); var bytes = new byte[identity.BinaryLength]; identity.GetBinaryForm(bytes, 0); attributes["objectSid"] = [bytes];
        }
        return new(dn, attributes);
    }
    private sealed class Fixture : IDisposable
    {
        internal AdBoundaryTests.RecordingAdConnection Connection { get; } = new();
        internal AdDirectorySource Source { get; }
        internal AdAuditReader Reader { get; }
        private Fixture() { Source = new("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: Connection); Reader = new(Source); }
        internal static async Task<Fixture> Create()
        {
            var fixture = new Fixture();
            await fixture.Source.RefreshAsync(MeasureFamily.Directory, new(Fixtures.People, "Personnes", true), CancellationToken.None);
            fixture.Connection.Searches.Clear(); return fixture;
        }
        public void Dispose() { Source.Dispose(); Connection.Dispose(); }
    }
}
