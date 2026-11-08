using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class AdFicheWriteTests
{
    [Test]
    public static async Task Fresh_native_write_distinguishes_a_qualified_empty_field_from_masked_or_confidential_values()
    {
        foreach (var readable in new[] { true, false })
        {
            using var ldap = new Connection(); using var source = Source(ldap);
            ldap.Objects[Dn]["adminCount"] = ["0"]; ldap.Objects[Dn]["isCriticalSystemObject"] = ["FALSE"];
            ldap.Objects[Dn].Remove("description");
            if (!readable) ldap.Objects[Dn].Remove("nTSecurityDescriptor");
            var writer = new AdObjectUpdateExecutor(source);
            var fields = new Dictionary<string, string?> { ["description"] = "Ajout confirmé" };
            if (readable)
            {
                var plan = Seal(await writer.PlanAsync(Dn, fields, default));
                Check.Null(plan.Changes[0].BeforeValue, "vraie absence qualifiée par DACL et schéma");
                Check.Equal(WriteChangeKind.Add, plan.Changes[0].Kind, "ajout, jamais remplacement aveugle");
                await writer.ExecuteAsync(plan, default);
                Check.Equal(1, ldap.Writes, "une seule requête native");
                Check.Equal(AdModificationKind.Add, ldap.Changes.Single().Kind, "aucun delete sans valeur précédente");
            }
            else
            {
                await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, fields, default), "une valeur masquée n’est pas vide");
                Check.Equal(0, ldap.Writes, "aucun contact de mutation");
            }
        }
        foreach (var flags in new int?[] { 128, 512, null })
        {
            using var ldap = new Connection { AbsenceSchemaFlags = flags }; using var source = Source(ldap);
            ldap.Objects[Dn]["adminCount"] = ["0"]; ldap.Objects[Dn]["isCriticalSystemObject"] = ["FALSE"];
            ldap.Objects[Dn].Remove("description");
            await Check.ThrowsAsync<DomeniaOperationException>(() => new AdObjectUpdateExecutor(source).PlanAsync(Dn,
                new Dictionary<string, string?> { ["description"] = "Invisible" }, default), "droit général insuffisant pour schéma confidentiel, filtré ou inconnu");
            Check.Equal(0, ldap.Writes, "aucune mutation de champ masqué");
        }
    }

    [Test]
    public static async Task Absence_is_not_qualified_across_a_schema_change_or_a_newly_unmasked_value()
    {
        foreach (var changedSchema in new[] { true, false })
        {
            using var ldap = new Connection(); using var source = Source(ldap);
            ldap.Objects[Dn]["adminCount"] = ["0"]; ldap.Objects[Dn]["isCriticalSystemObject"] = ["FALSE"];
            ldap.Objects[Dn].Remove("description");
            ldap.OnAbsenceSchemaRead = count =>
            {
                if (changedSchema && count == 2) ldap.AbsenceSchemaVersion++;
                if (!changedSchema && count == 1) ldap.Objects[Dn]["description"] = ["Valeur masquée redevenue visible"];
            };
            await Check.ThrowsAsync<DomeniaOperationException>(() => new AdObjectUpdateExecutor(source).PlanAsync(Dn,
                new Dictionary<string, string?> { ["description"] = "Écrasement interdit" }, default), "preuve contradictoire pendant la qualification");
            Check.Equal(0, ldap.Writes, "aucune mutation fondée sur cette absence");
        }
    }

    [Test]
    public static async Task A_custom_raw_attribute_is_requalified_for_an_add_and_for_a_verified_clear()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Schema["customText"] = Schema("customText", "2.5.5.12", 64);
        var policy = FicheSecurityPolicy.Default with { AllowRawAttributeWrite = true };
        var writer = new AdRawAttributeExecutor(source, _ => Task.FromResult(policy));
        foreach (var value in new string?[] { "Valeur exacte", null })
        {
            var plan = Seal(await writer.PlanAsync(Dn, "customText", value, policy, default));
            writer.Remember(plan.Id, plan.ExpiresAt, policy);
            await writer.ExecuteAsync(plan, default);
            Check.Equal(VerificationState.Verified, (await writer.VerifyAsync(plan, default)).State, "valeur présente puis absence qualifiée de l’attribut demandé");
        }
        Check.Equal(2, ldap.Writes, "une requête atomique par geste explicite");
        ldap.Objects[Dn]["customText"] = ["À conserver"];
        var clear = Seal(await writer.PlanAsync(Dn, "customText", null, policy, default));
        ldap.Objects[Dn].Remove("customText"); ldap.Objects[Dn].Remove("nTSecurityDescriptor");
        Check.Equal(VerificationState.Unknown, (await writer.VerifyAsync(clear, default)).State, "un champ désormais masqué n’est pas un effacement vérifié");
    }

    [Test]
    public static async Task Ordinary_absent_protection_markers_are_allowed_only_with_read_proof_and_malformed_values_are_refused()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var writer = new AdObjectUpdateExecutor(source);
        var fields = new Dictionary<string, string?> { ["description"] = "Après" };
        var ordinary = await writer.PlanAsync(Dn, fields, default);
        Check.False(ordinary.Confirmation.TypedNameRequired, "objet ordinaire sans adminCount, DACL et schéma qualifiés");
        foreach (var value in new[] { "illisible", "-1", "2" })
        {
            ldap.Objects[Dn]["adminCount"] = [value];
            await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, fields, default), "adminCount mal formé jamais faux");
        }
        ldap.Objects[Dn].Remove("adminCount"); ldap.Objects[Dn]["isCriticalSystemObject"] = ["illisible"];
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, fields, default), "isCritical mal formé");
        ldap.Objects[Dn].Remove("isCriticalSystemObject"); ldap.Objects[Dn].Remove("nTSecurityDescriptor");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, fields, default), "protection masquée ou absence indécidable");
        Check.Equal(0, ldap.Writes, "préparation en lecture seule");
    }

    [Test]
    public static async Task The_pinned_native_version_rejects_even_an_unrelated_concurrent_change_but_allows_a_real_no_change()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var writer = new AdObjectUpdateExecutor(source);
        var plan = Seal(await writer.PlanAsync(Dn, new Dictionary<string, string?> { ["description"] = "Après" }, default));
        Check.Equal(1L, plan.Target.DirectoryUsn, "version native scellée");
        Check.False(WritePlans.IsIntact(plan with { Target = plan.Target with { DirectoryUsn = 2 } }), "version couverte par empreinte");
        ldap.Objects[Dn]["uSNChanged"] = ["2"]; ldap.Objects[Dn]["title"] = ["Changement étranger"];
        Check.False((await writer.CheckAsync(plan, default)).Current, "version différente même si valeur avant inchangée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, default), "aucun nouvel envoi après changement");
        Check.Equal(0, ldap.Writes, "zéro mutation");
        ldap.Objects[Dn]["description"] = ["Après"];
        Check.Equal(WriteResult.NoChange, (await writer.ExecuteAsync(plan, default)).Result, "état déjà intégralement conforme relu");
        Check.Equal(0, ldap.Writes, "NoChange n’envoie rien");
    }

    [Test]
    public static async Task An_identical_GUID_and_USN_never_authorize_update_or_raw_write_after_a_DN_change()
    {
        foreach (var raw in new[] { false, true })
        {
            using var ldap = new Connection(); using var source = Source(ldap);
            var policy = FicheSecurityPolicy.Default with { AllowRawAttributeWrite = true };
            ldap.Schema["description"] = Schema("description", "2.5.5.12", 64);
            var rawWriter = new AdRawAttributeExecutor(source, _ => Task.FromResult(policy));
            IWriteExecutor writer = raw ? rawWriter : new AdObjectUpdateExecutor(source);
            var draft = raw ? await rawWriter.PlanAsync(Dn, "description", "Après", policy, default)
                : await ((AdObjectUpdateExecutor)writer).PlanAsync(Dn, new Dictionary<string, string?> { ["description"] = "Après" }, default);
            var plan = Seal(draft); rawWriter.Remember(plan.Id, plan.ExpiresAt, policy);
            var moved = "CN=Renommé," + Fixtures.People;
            ldap.Objects[moved] = ldap.Objects[Dn]; ldap.Objects.Remove(Dn);
            Check.False((await writer.CheckAsync(plan, default)).Current, "DN différent malgré GUID et USN identiques");
            await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, default), "aucun envoi après déplacement");
            Check.Equal(0, ldap.Writes, "aucune mutation");
        }
    }

    [Test]
    public static async Task A_changed_mutated_group_version_refuses_a_computer_membership_even_with_an_unchanged_computer()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Objects[Dn]["objectClass"] = ["top", "computer"]; ldap.Objects[Dn]["userAccountControl"] = ["4096"]; ldap.Objects[Dn]["sAMAccountName"] = ["PC-ORIG$"];
        ldap.Objects[Manager]["objectClass"] = ["top", "group"]; ldap.Objects[Manager]["groupType"] = ["-2147483646"];
        var writer = new AdPosteGroupExecutor(source);
        var plan = Seal(await writer.PlanAsync(Dn, Manager, true, default));
        Check.Equal(1L, plan.Changes.Single().ReferenceUsn, "version du groupe réellement modifié");
        ldap.Objects[Manager]["uSNChanged"] = ["2"];
        Check.False((await writer.CheckAsync(plan, default)).Current, "groupe changé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, default), "aucun envoi");
        Check.Equal(0, ldap.Writes, "autres appartenances préservées");
    }
}
