using System.Security.Principal;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Queries.Ldap;

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

    [Test]
    public static async Task Raw_binary_changes_preserve_octets_and_are_verified_after_a_single_modify()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Objects[Dn]["customBinary"] = [new byte[] { 0, 255, 128 }];
        ldap.Schema["customBinary"] = Schema("customBinary", "2.5.5.10", 4);
        var policy = FicheSecurityPolicy.Default with { AllowRawAttributeWrite = true };
        var writer = new AdRawAttributeExecutor(source, _ => Task.FromResult(policy));
        var plan = Seal(await writer.PlanAsync(Dn, "customBinary", "fefe00", policy, CancellationToken.None));
        Check.Equal("00FF80", plan.Changes[0].BeforeValue, "octets précédents exacts");
        Check.Equal("FEFE00", plan.Changes[0].AfterValue, "hexadécimal canonique confirmé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "politique non déposée");
        writer.Remember(plan.Id, plan.ExpiresAt, policy);
        await writer.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal(1, ldap.Writes, "une requête");
        Check.True(((byte[])ldap.Changes[0].Values[0]).SequenceEqual(new byte[] { 0, 255, 128 }), "suppression compare les vrais octets");
        Check.True(((byte[])ldap.Changes[1].Values[0]).SequenceEqual(new byte[] { 254, 254, 0 }), "nouvelle valeur binaire, aucun texte UTF-8");
        Check.Equal(VerificationState.Verified, (await writer.VerifyAsync(plan, CancellationToken.None)).State, "octets relus");
    }

    [Test]
    public static async Task Raw_write_rechecks_native_policy_schema_and_reference_identity()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Schema["manager"] = Schema("manager", "2.5.5.1", 127);
        var policy = FicheSecurityPolicy.Default with { AllowRawAttributeWrite = true };
        var native = policy;
        var writer = new AdRawAttributeExecutor(source, _ => Task.FromResult(native));
        var plan = Seal(await writer.PlanAsync(Dn, "manager", Manager.ToLowerInvariant(), policy, CancellationToken.None));
        Check.Equal(ldap.Id(Manager).ToString("D"), plan.Changes[0].ReferenceGuid, "référence scellée même dans l’éditeur brut");
        writer.Remember(plan.Id, plan.ExpiresAt, policy);
        native = FicheSecurityPolicy.Default;
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "politique native refermée");
        native = policy;
        ldap.Schema["manager"] = Schema("manager", "2.5.5.1", 127, new() { ["systemOnly"] = ["TRUE"] });
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "attribut devenu système");
        ldap.Schema["manager"] = Schema("manager", "2.5.5.1", 127);
        ldap.Objects[Manager]["objectGUID"] = [Guid.NewGuid().ToByteArray()];
        Check.False((await writer.CheckAsync(plan, CancellationToken.None)).Current, "responsable remplacé");
        Check.Equal(0, ldap.Writes, "aucun envoi");
    }

    [Test]
    public static async Task Raw_native_default_never_trusts_a_page_policy_that_opens_writes()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var writer = new AdRawAttributeExecutor(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, "description", "Autre", FicheSecurityPolicy.Simulation, CancellationToken.None), "configuration hôte requise");
        Check.Equal(0, ldap.Writes, "aucune mutation");
    }

    [Test]
    public static void Raw_schema_refuses_composite_system_backlink_or_malformed_values()
    {
        var binary = AdRawAttributeSchema.From(Schema("customBinary", "2.5.5.10", 4, new() { ["rangeUpper"] = ["2"] }));
        Check.Equal("00FF", binary.Normalize("00ff"), "normalisation hexadécimale");
        foreach (var value in new[] { "XYZ", "0", "001122" }) { Check.Throws<DomeniaOperationException>(() => binary.Encode(value), "hexadécimal invalide ou trop long"); }
        foreach (var extra in new Dictionary<string, IReadOnlyList<object>>[]
        {
            new() { ["systemOnly"] = ["TRUE"] }, new() { ["isDefunct"] = ["TRUE"] }, new() { ["systemFlags"] = ["4"] }, new() { ["linkID"] = ["3"] },
            new() { ["systemFlags"] = ["illisible"] }, new() { ["rangeUpper"] = ["-1"] },
        }) { Check.Throws<DomeniaOperationException>(() => AdRawAttributeSchema.From(Schema("custom", "2.5.5.12", 64, extra)), "schéma non modifiable"); }
        Check.Throws<DomeniaOperationException>(() => AdRawAttributeSchema.From(Schema("descriptor", "2.5.5.15", 66)), "descripteur partiel interdit au brut");
        Check.Throws<DomeniaOperationException>(() => AdRawAttributeSchema.From(Schema("custom", "2.5.5.12", 4)), "couple syntaxe OM incohérent");
        var number = AdRawAttributeSchema.From(Schema("customNumber", "2.5.5.9", 2));
        Check.Equal("12", number.Normalize("+0012"), "entier canonique");
        Check.Throws<DomeniaOperationException>(() => number.Normalize("2147483648"), "débordement refusé");
    }

    [Test]
    public static async Task One_member_beyond_the_initial_range_is_removed_without_replacing_other_members()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Objects[Manager]["objectClass"] = ["top", "group"];
        ldap.Objects[Manager]["groupType"] = ["-2147483646"];
        var members = Enumerable.Range(0, 3000).Select(n => (object)("CN=Membre-" + n + "," + Fixtures.People)).ToList();
        members[2000] = Dn; ldap.Objects[Manager]["member"] = members.ToArray();
        var writer = new AdGroupMemberExecutor(source);
        var plan = Seal(await writer.PlanAsync(Manager, Dn, false, CancellationToken.None));
        Check.True(plan.Confirmation.TypedNameRequired, "retrait confirmé par nom");
        await writer.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal(1, ldap.Changes.Count, "une valeur retirée, aucune réécriture de liste");
        Check.Equal("<GUID=" + ldap.Id(Dn).ToString("D") + ">", (string)ldap.Changes[0].Values[0], "identité du membre dans Modify");
        Check.Equal(2999, ldap.Objects[Manager]["member"].Count, "tous les autres membres conservés");
        Check.True(ldap.Objects[Manager]["member"].SequenceEqual(members.Where(m => !Equals(m, Dn))), "liste restante exacte");
        Check.Equal(VerificationState.Verified, (await writer.VerifyAsync(plan, CancellationToken.None)).State, "absence de cette appartenance confirmée");
        Check.Equal(WriteResult.NoChange, (await writer.ExecuteAsync(plan, CancellationToken.None)).Result, "pas de second retrait");
    }

    [Test]
    public static async Task Group_add_never_follows_a_recreated_member_or_a_newly_protected_group()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Objects[Manager]["objectClass"] = ["top", "group"]; ldap.Objects[Manager]["groupType"] = ["-2147483646"];
        var writer = new AdGroupMemberExecutor(source);
        var plan = Seal(await writer.PlanAsync(Manager, Dn, true, CancellationToken.None));
        var guid = ldap.Objects[Dn]["objectGUID"];
        ldap.Objects[Dn]["objectGUID"] = [Guid.NewGuid().ToByteArray()];
        Check.False((await writer.CheckAsync(plan, CancellationToken.None)).Current, "ancien membre remplacé");
        ldap.Objects[Dn]["objectGUID"] = guid; ldap.Objects[Manager]["adminCount"] = ["1"];
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "groupe protégé depuis le plan");
        Check.Equal(0, ldap.Writes, "aucune écriture");
        ldap.Objects[Manager].Remove("adminCount");
        await writer.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal(VerificationState.Verified, (await writer.VerifyAsync(plan, CancellationToken.None)).State, "appartenance ajoutée relue");
    }

    [Test]
    public static async Task Move_keeps_the_exact_escaped_RDN_and_targets_both_GUIDs()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        const string destination = "OU=Destination," + Fixtures.Root;
        const string unusual = "CN=Compte\\, spécial," + Fixtures.People;
        ldap.Objects[unusual] = ldap.Objects[Dn]; ldap.Objects.Remove(Dn);
        ldap.Objects[destination] = new(StringComparer.OrdinalIgnoreCase)
        { ["objectGUID"] = [Fixtures.IdOf(destination).ToByteArray()], ["name"] = ["Destination"], ["objectClass"] = ["top", "organizationalUnit"], ["uSNChanged"] = ["1"] };
        var id = ldap.Id(unusual); var writer = new AdObjectMoveExecutor(source);
        var plan = Seal(await writer.PlanAsync(unusual, destination, id, CancellationToken.None));
        await writer.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal("<GUID=" + id.ToString("D") + ">", ldap.RenamedTarget, "source par GUID");
        Check.Equal("<GUID=" + ldap.Id(destination).ToString("D") + ">", ldap.RenamedParent, "destination par GUID");
        Check.Equal("CN=Compte\\, spécial", ldap.RenamedRdn, "nom inchangé et virgule échappée");
        Check.Equal(VerificationState.Verified, (await writer.VerifyAsync(plan, CancellationToken.None)).State, "nom, GUID et emplacement relus");
        Check.Equal(WriteResult.NoChange, (await writer.ExecuteAsync(plan, CancellationToken.None)).Result, "aucun déplacement répété");
        Check.Equal(1, ldap.Writes, "une seule requête");
    }

    [Test]
    public static async Task Move_refuses_recreated_destination_name_collision_and_changed_name()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        const string destination = "OU=Destination," + Fixtures.Root;
        ldap.Objects[destination] = new(StringComparer.OrdinalIgnoreCase)
        { ["objectGUID"] = [Fixtures.IdOf(destination).ToByteArray()], ["name"] = ["Destination"], ["objectClass"] = ["top", "organizationalUnit"], ["uSNChanged"] = ["1"] };
        var writer = new AdObjectMoveExecutor(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, destination, Guid.NewGuid(), CancellationToken.None), "identité du sélecteur périmée");
        var plan = Seal(await writer.PlanAsync(Dn, destination, null, CancellationToken.None));
        var destinationId = ldap.Objects[destination]["objectGUID"];
        ldap.Objects[destination]["objectGUID"] = [Guid.NewGuid().ToByteArray()];
        Check.False((await writer.CheckAsync(plan, CancellationToken.None)).Current, "destination recréée");
        ldap.Objects[destination]["objectGUID"] = destinationId;
        var collision = "CN=Compte," + destination;
        ldap.Objects[collision] = new(ldap.Objects[Dn], StringComparer.OrdinalIgnoreCase) { ["objectGUID"] = [Guid.NewGuid().ToByteArray()] };
        Check.False((await writer.CheckAsync(plan, CancellationToken.None)).Current, "collision apparue après plan");
        ldap.Objects.Remove(collision);
        ldap.Objects["CN=Renommé," + destination] = ldap.Objects[Dn]; ldap.Objects.Remove(Dn);
        Check.False((await writer.CheckAsync(plan, CancellationToken.None)).Current, "même destination, mais nom différent");
        Check.Equal(VerificationState.Mismatch, (await writer.VerifyAsync(plan, CancellationToken.None)).State, "la seule OU ne prouve pas le déplacement confirmé");
        Check.Equal(0, ldap.Writes, "rien envoyé");
    }

    [Test]
    public static async Task Ou_creation_is_one_add_with_an_escaped_name_and_never_a_parent_update()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Objects[Fixtures.Root] = new(StringComparer.OrdinalIgnoreCase)
        { ["objectGUID"] = [Fixtures.IdOf(Fixtures.Root).ToByteArray()], ["name"] = ["test"], ["objectClass"] = ["top", "domainDNS"], ["uSNChanged"] = ["1"], ["isCriticalSystemObject"] = ["TRUE"] };
        var writer = new AdOuCreateExecutor(source);
        var plan = Seal(await writer.PlanAsync(Fixtures.Root, "Équipe, Paris", CancellationToken.None));
        Check.Equal(Fixtures.IdOf(Fixtures.Root).ToString("D"), plan.Target.ObjectGuid, "identité du parent confirmée");
        Check.True((await writer.CheckAsync(plan, CancellationToken.None)).Current, "nom encore libre");
        var outcome = await writer.ExecuteAsync(plan, CancellationToken.None);
        var child = DistinguishedName.Child("OU", "Équipe, Paris", Fixtures.Root);
        Check.Equal(child, ldap.AddedDn, "nom échappé");
        Check.True(ldap.AddedAttributes!.Keys.Order().SequenceEqual(new[] { "objectClass", "ou" }.Order()), "seule la nouvelle OU est envoyée");
        Check.Equal(1, ldap.Writes, "une requête Add");
        Check.Equal(VerificationState.Verified, (await writer.VerifyOutcomeAsync(plan, outcome.Result, CancellationToken.None)).State, "acceptation et emplacement relus");
        Check.False((await writer.CheckAsync(plan, CancellationToken.None)).Current, "nom désormais pris, aucune seconde création");
        Check.Equal("TRUE", (string)ldap.Objects[Fixtures.Root]["isCriticalSystemObject"][0], "parent intact");
    }

    [Test]
    public static async Task An_unknown_ou_add_response_is_never_proved_by_a_same_name_object()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Objects[Fixtures.People] = new(StringComparer.OrdinalIgnoreCase)
        { ["objectGUID"] = [Fixtures.IdOf(Fixtures.People).ToByteArray()], ["name"] = ["People"], ["objectClass"] = ["top", "organizationalUnit"], ["uSNChanged"] = ["1"] };
        var writer = new AdOuCreateExecutor(source);
        var plan = Seal(await writer.PlanAsync(Fixtures.People, "Nouvelle", CancellationToken.None));
        await writer.ExecuteAsync(plan, CancellationToken.None);
        Check.Equal(VerificationState.Unknown, (await writer.VerifyOutcomeAsync(plan, WriteResult.Unknown, CancellationToken.None)).State, "présence ne prouve pas origine de création");
        Check.Equal(VerificationState.Unknown, (await writer.VerifyAsync(plan, CancellationToken.None)).State, "relecture sans reçu d’acceptation conservatrice");
        Check.Equal(VerificationState.Mismatch, (await writer.VerifyOutcomeAsync(plan, WriteResult.NotApplied, CancellationToken.None)).State, "refus n’est pas un succès");
        ldap.Objects[Fixtures.People]["objectGUID"] = [Guid.NewGuid().ToByteArray()];
        Check.Equal(VerificationState.Mismatch, (await writer.VerifyOutcomeAsync(plan, WriteResult.Applied, CancellationToken.None)).State, "parent remplacé");
    }

    [Test]
    public static async Task Ou_creation_refuses_invalid_names_and_parent_replacement_before_add()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Objects[Fixtures.People] = new(StringComparer.OrdinalIgnoreCase)
        { ["objectGUID"] = [Fixtures.IdOf(Fixtures.People).ToByteArray()], ["name"] = ["People"], ["objectClass"] = ["top", "organizationalUnit"], ["uSNChanged"] = ["1"] };
        var writer = new AdOuCreateExecutor(source);
        foreach (var name in new[] { " ", "#Interdit", new string('a', 65), "inter\nrompu" })
        { await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Fixtures.People, name, CancellationToken.None), "nom non admis"); }
        var plan = Seal(await writer.PlanAsync(Fixtures.People, "Nouvelle", CancellationToken.None));
        ldap.Objects[Fixtures.People]["objectGUID"] = [Guid.NewGuid().ToByteArray()];
        Check.False((await writer.CheckAsync(plan, CancellationToken.None)).Current, "ancien parent absent");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "pas de création sous un homonyme");
        Check.Equal(0, ldap.Writes, "aucun envoi");
    }

    private static AdEntry Schema(string name, string syntax, int om, Dictionary<string, IReadOnlyList<object>>? extras = null)
    {
        var fields = extras ?? new(StringComparer.OrdinalIgnoreCase);
        fields["lDAPDisplayName"] = [name]; fields["attributeSyntax"] = [syntax]; fields["oMSyntax"] = [om.ToString(System.Globalization.CultureInfo.InvariantCulture)];
        return new("CN=" + name + ",CN=Schema,CN=Configuration," + Fixtures.Root, fields);
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
        internal string? AddedDn { get; private set; }
        internal IReadOnlyDictionary<string, IReadOnlyList<object>>? AddedAttributes { get; private set; }
        internal string? RenamedTarget { get; private set; }
        internal string? RenamedParent { get; private set; }
        internal string? RenamedRdn { get; private set; }
        internal int Writes { get; private set; }
        internal IReadOnlyList<AdModification> Changes { get; private set; } = [];
        internal Dictionary<string, AdEntry> Schema { get; } = new(StringComparer.OrdinalIgnoreCase);
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
        public Task<AdRootDse> RootDseAsync(CancellationToken cancellationToken) => Task.FromResult(new AdRootDse(Fixtures.Root, "CN=Configuration," + Fixtures.Root, "CN=Schema,CN=Configuration," + Fixtures.Root, Fixtures.Root, Server, null, 7, [], Fixtures.Now));
        public Task<AdEntry?> ReadAsync(string distinguishedName, IReadOnlyList<string> attributes, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (request.Scope == AdSearchScope.OneLevel && request.BaseDn.StartsWith("CN=Schema,", StringComparison.OrdinalIgnoreCase))
            { return Task.FromResult<IReadOnlyList<AdEntry>>([.. Schema.Where(p => request.Filter.Contains("(lDAPDisplayName=" + p.Key + ")", StringComparison.OrdinalIgnoreCase)).Select(p => p.Value)]); }
            var selected = Objects.Where(p => request.Scope == AdSearchScope.Base ? FicheValues.SameDn(p.Key, request.BaseDn) : request.Filter == AdObjectAccess.GuidFilter(Id(p.Key)));
            if (request.Filter.Contains("(member=", StringComparison.Ordinal))
            {
                var filter = LdapFilterText.Parse(request.Filter);
                var member = filter.Children.Single(c => c.Attribute == "member").Text;
                selected = selected.Where(p => request.Filter.Contains(AdObjectAccess.GuidFilter(Id(p.Key)), StringComparison.Ordinal)
                    && p.Value.TryGetValue("member", out var values) && values.OfType<string>().Any(v => FicheValues.SameDn(v, member)));
            }
            return Task.FromResult<IReadOnlyList<AdEntry>>([.. selected.Select(p =>
            {
                var values = new Dictionary<string, IReadOnlyList<object>>(p.Value, StringComparer.OrdinalIgnoreCase)
                { ["allowedAttributes"] = p.Value.Keys.Concat(["mail", "manager", "managedBy"]).Distinct(StringComparer.OrdinalIgnoreCase).Select(a => (object)a).ToArray() };
                if (request.Attributes.Contains("member;range=0-1499") && values.TryGetValue("member", out var members) && members.Count > 1499)
                { values.Remove("member"); values["member;range=0-1499"] = members.Take(1500).ToArray(); }
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
                if (change.Attribute == "member")
                {
                    var member = Objects.Keys.Single(dn => Equals(change.Values.Single(), "<GUID=" + Id(dn).ToString("D") + ">"));
                    var oldMembers = next.TryGetValue("member", out var existing) ? existing : [];
                    var present = oldMembers.OfType<string>().Any(v => FicheValues.SameDn(v, member));
                    if (present == (change.Kind == AdModificationKind.Add)) { throw new DomeniaOperationException(AdErrors.Constraint, "Appartenance concurrente"); }
                    next["member"] = change.Kind == AdModificationKind.Add ? [.. oldMembers, member] : [.. oldMembers.Where(v => !FicheValues.SameDn((string)v, member))];
                    continue;
                }
                if (change.Kind == AdModificationKind.Delete)
                {
                    if (!next.TryGetValue(change.Attribute, out var old) || !old.Zip(change.Values).All(p => p.First is byte[] a && p.Second is byte[] b ? a.SequenceEqual(b) : Equals(p.First, p.Second)) || old.Count != change.Values.Count) { throw new DomeniaOperationException(AdErrors.Constraint, "Valeur concurrente"); }
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
        public Task RenameAsync(string distinguishedName, string newParentDn, string newRdn, CancellationToken cancellationToken)
        {
            RenamedTarget = distinguishedName; RenamedParent = newParentDn; RenamedRdn = newRdn;
            var target = Objects.Keys.Single(dn => distinguishedName == "<GUID=" + Id(dn).ToString("D") + ">");
            var parent = Objects.Keys.Single(dn => newParentDn == "<GUID=" + Id(dn).ToString("D") + ">");
            var moved = newRdn + "," + parent;
            if (Objects.ContainsKey(moved)) { throw new DomeniaOperationException(AdErrors.Exists, "Collision"); }
            Objects[moved] = Objects[target]; Objects.Remove(target); Writes++;
            return Task.CompletedTask;
        }
        public Task AddAsync(string distinguishedName, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken cancellationToken)
        {
            if (Objects.ContainsKey(distinguishedName)) { throw new DomeniaOperationException(AdErrors.Exists, "Existe déjà"); }
            if (!Objects.ContainsKey(DistinguishedName.Parent(distinguishedName)!)) { throw new DomeniaOperationException(AdErrors.NoSuchObject, "Parent absent"); }
            AddedDn = distinguishedName; AddedAttributes = attributes;
            Objects[distinguishedName] = new(attributes, StringComparer.OrdinalIgnoreCase)
            { ["objectGUID"] = [Guid.NewGuid().ToByteArray()], ["name"] = [DistinguishedName.Parse(distinguishedName)[0].Value], ["uSNChanged"] = ["1"] };
            Writes++;
            return Task.CompletedTask;
        }
        public Task DeleteAsync(string distinguishedName, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public void Dispose() { }
    }
}
