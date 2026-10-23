using System.Security.Principal;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdFicheWriteTests
{
    private const string Dn = "CN=Compte," + Fixtures.People;
    private const string Manager = "CN=Responsable," + Fixtures.People;
    private const string Login = "TEST\\operateur";

    [Test]
    public static async Task Fiche_profile_account_state_options_and_password_expiry_write_only_the_planned_attributes()
    {
        foreach (var kind in new[] { ObjectWrites.UpdateKind, ObjectWrites.EnabledKind, ObjectWrites.OptionsKind, ObjectWrites.ExpirePasswordKind })
        {
            using var ldap = new Connection(); using var source = Source(ldap);
            using var writers = WriteExecutors.Discover(source, [typeof(AdDirectorySource).Assembly]);
            var executor = writers.ForKind(kind)!;
            var draft = kind switch
            {
                ObjectWrites.UpdateKind => await ((IObjectUpdateExecutor)executor).PlanAsync(Dn, new Dictionary<string, string?> { ["description"] = "Nouvelle", ["mail"] = "compte@test.local" }, CancellationToken.None),
                ObjectWrites.EnabledKind => await ((IAccountEnabledExecutor)executor).PlanAsync(Dn, false, CancellationToken.None),
                ObjectWrites.OptionsKind => await ((IAccountOptionsExecutor)executor).PlanAsync(Dn, new Dictionary<string, bool> { [FicheSheets.OptionFlags.First().Id] = true }, FicheSecurityPolicy.Default, CancellationToken.None),
                _ => await ((IPasswordExpireExecutor)executor).PlanAsync(Dn, CancellationToken.None),
            };
            var plan = Seal(draft);
            Check.True(draft.Origin!.Matches(await source.GetSessionAsync(CancellationToken.None)), "lecture liée à sa session");
            Check.True((await executor.CheckAsync(plan, CancellationToken.None)).Current, "état frais inchangé");
            Check.Equal(0, ldap.Writes, "plan et préconditions en lecture seule");
            Check.Equal(WriteResult.Applied, (await executor.ExecuteAsync(plan, CancellationToken.None)).Result, "envoi accepté");
            Check.Equal(1, ldap.Writes, "une seule requête");
            Check.True(ldap.Changes.All(c => plan.Changes.Any(p => p.Attribute == c.Attribute)), "seuls les champs confirmés");
            Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(plan, CancellationToken.None)).State, "valeurs relues conformes");
            Check.Equal(WriteResult.NoChange, (await executor.ExecuteAsync(plan, CancellationToken.None)).Result, "seconde demande constatée déjà faite");
            Check.Equal(1, ldap.Writes, "aucun renvoi inutile");
        }
    }

    [Test]
    public static async Task Manager_references_are_canonical_sealed_and_never_follow_a_recreated_homonym()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var executor = new AdObjectUpdateExecutor(source);
        var plan = Seal(await executor.PlanAsync(Dn, new Dictionary<string, string?> { ["manager"] = Manager.ToLowerInvariant() }, CancellationToken.None));
        Check.Equal(Manager, plan.Changes[0].AfterValue, "DN canonique relu");
        Check.Equal(ldap.Id(Manager).ToString("D"), plan.Changes[0].ReferenceGuid, "GUID du responsable scellé");
        var json = JsonSerializer.Serialize(plan);
        var reread = JsonSerializer.Deserialize<WritePlan>(json)!;
        Check.True(WritePlans.IsIntact(reread), "identité conservée dans le reçu");
        Check.False(WritePlans.IsIntact(plan with { Changes = [plan.Changes[0] with { ReferenceGuid = Guid.NewGuid().ToString("D") }] }), "GUID couvert par l’empreinte");
        ldap.Objects[Manager]["objectGUID"] = [Guid.NewGuid().ToByteArray()];
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "responsable recréé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "aucun homonyme substitué");
        Check.Equal(0, ldap.Writes, "aucune écriture");
    }

    [Test]
    public static async Task A_manager_is_written_by_its_GUID_and_confirmed_as_the_canonical_DN()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var executor = new AdObjectUpdateExecutor(source);
        var plan = Seal(await executor.PlanAsync(Dn, new Dictionary<string, string?> { ["manager"] = Manager }, CancellationToken.None));
        await executor.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal("<GUID=" + ldap.Id(Manager).ToString("D") + ">", (string)ldap.Changes.Single().Values.Single(), "identité du gestionnaire dans Modify");
        Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(plan, CancellationToken.None)).State, "DN LDAP relu");
    }

    [Test]
    public static async Task New_protection_multi_values_or_a_replaced_target_refuse_profile_changes()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var executor = new AdObjectUpdateExecutor(source);
        var plan = Seal(await executor.PlanAsync(Dn, new Dictionary<string, string?> { ["description"] = "Nouvelle" }, CancellationToken.None));
        ldap.Objects[Dn]["adminCount"] = ["1"];
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "confirmation renforcée devenue nécessaire");
        ldap.Objects[Dn].Remove("adminCount");
        ldap.Objects[Dn]["description"] = ["Ancienne", "Autre"];
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "plusieurs valeurs non écrasées");
        ldap.Objects[Dn]["description"] = ["Ancienne"];
        ldap.Objects[Dn]["objectGUID"] = [Guid.NewGuid().ToByteArray()];
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "ancien GUID disparu");
        Check.Equal(0, ldap.Writes, "rien envoyé");
    }

    [Test]
    public static async Task A_fiche_cannot_disable_the_operator_or_a_domain_controller_or_edit_managed_accounts()
    {
        using var ldap = new Connection(); using var source = Source(ldap, Dn);
        var state = new AdAccountEnabledExecutor(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => state.PlanAsync(Dn, false, CancellationToken.None), "soi-même");
        ldap.Objects[Manager]["objectClass"] = ["top", "computer"]; ldap.Objects[Manager]["userAccountControl"] = ["8192"];
        await Check.ThrowsAsync<DomeniaOperationException>(() => state.PlanAsync(Manager, false, CancellationToken.None), "contrôleur du domaine");
        ldap.Objects[Manager]["objectClass"] = ["top", "user", "msDS-GroupManagedServiceAccount"];
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdObjectUpdateExecutor(source).PlanAsync(Manager, new Dictionary<string, string?> { ["description"] = "Test" }, CancellationToken.None), "service géré");
        Check.Equal(0, ldap.Writes, "aucune modification");
    }

    private static WritePlan Seal(WritePlanDraft draft) => WritePlans.Seal(draft, WritePlans.NewId(), Login, AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
    private static AdDirectorySource Source(Connection ldap, string? operatorDn = null)
    {
        var source = new AdDirectorySource("test.local", () => Login, TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection());
        source.AdoptConnection(ldap, Fixtures.Domain, new(new(Login, "Opérateur", null, operatorDn ?? "CN=Operateur," + Fixtures.People), Fixtures.Domain.DomainSid + "-1100",
            new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), source.Epoch, false);
        return source;
    }

    private sealed class Connection : IAdConnection
    {
        internal Dictionary<string, Dictionary<string, IReadOnlyList<object>>> Objects { get; } = new(StringComparer.OrdinalIgnoreCase);
        internal int Writes { get; private set; }
        internal IReadOnlyList<AdModification> Changes { get; private set; } = [];
        public string Server => "DC1.test.local";
        internal Guid Id(string dn) => new((byte[])Objects[dn]["objectGUID"][0]);
        internal Connection()
        {
            foreach (var dn in new[] { Dn, Manager })
            {
                var sid = new SecurityIdentifier(Fixtures.Domain.DomainSid + "-1001"); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
                Objects[dn] = new(StringComparer.OrdinalIgnoreCase)
                {
                    ["objectGUID"] = [Fixtures.IdOf(dn).ToByteArray()], ["objectSid"] = [bytes], ["objectClass"] = ["top", "user"], ["name"] = [FicheValues.DisplayName(dn)],
                    ["sAMAccountName"] = ["compte"], ["uSNChanged"] = ["1"], ["userAccountControl"] = ["512"],
                    ["pwdLastSet"] = [AccountWrites.Raw(AdValues.ToFileTime(Fixtures.Now.AddDays(-1)))], ["description"] = ["Ancienne"],
                };
            }
        }
        public Task<AdRootDse> RootDseAsync(CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task<AdEntry?> ReadAsync(string distinguishedName, IReadOnlyList<string> attributes, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var selected = Objects.Where(p => request.Scope == AdSearchScope.Base ? FicheValues.SameDn(p.Key, request.BaseDn) : request.Filter == AdObjectAccess.GuidFilter(Id(p.Key)));
            return Task.FromResult<IReadOnlyList<AdEntry>>([.. selected.Select(p =>
            {
                var values = new Dictionary<string, IReadOnlyList<object>>(p.Value, StringComparer.OrdinalIgnoreCase)
                { ["allowedAttributes"] = p.Value.Keys.Concat(["mail", "manager", "managedBy"]).Distinct(StringComparer.OrdinalIgnoreCase).Select(a => (object)a).ToArray() };
                return new AdEntry(p.Key, values);
            })]);
        }
        public Task ModifyAsync(string distinguishedName, IReadOnlyList<AdModification> modifications, CancellationToken cancellationToken)
        {
            Writes++; Changes = modifications;
            var target = Objects.Single(p => distinguishedName == "<GUID=" + Id(p.Key).ToString("D") + ">");
            var next = new Dictionary<string, IReadOnlyList<object>>(target.Value, StringComparer.OrdinalIgnoreCase);
            foreach (var change in modifications)
            {
                if (change.Kind == AdModificationKind.Delete)
                {
                    if (!next.TryGetValue(change.Attribute, out var old) || !old.SequenceEqual(change.Values)) { throw new DomeniaOperationException(AdErrors.Constraint, "Valeur concurrente"); }
                    next.Remove(change.Attribute);
                }
                else
                {
                    if (change.Kind == AdModificationKind.Add && next.ContainsKey(change.Attribute)) { throw new DomeniaOperationException(AdErrors.Exists, "Valeur déjà présente"); }
                    next[change.Attribute] = change.Values.Select(v => v is string text && text.StartsWith("<GUID=", StringComparison.Ordinal)
                        ? (object)Objects.Keys.Single(dn => text == "<GUID=" + Id(dn).ToString("D") + ">") : v).ToArray();
                }
            }
            Objects[target.Key] = next;
            return Task.CompletedTask;
        }
        public Task RenameAsync(string distinguishedName, string newParentDn, string newRdn, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task AddAsync(string distinguishedName, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task DeleteAsync(string distinguishedName, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public void Dispose() { }
    }
}
