using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Tests;

internal static class NativeAcceptanceGuardTests
{
    private static readonly DateTimeOffset Created = new(2026, 10, 20, 10, 0, 0, TimeSpan.Zero);
    private static NativeAcceptanceTarget Target(string name, int rid, string? host = null) => new("CN=" + name + "," + NativeAcceptanceManifest.Scope,
        Fixtures.IdOf(name), "S-1-5-21-1-2-3-" + rid, Created, name, host);
    private static NativeAcceptanceManifest Manifest() => new("Domenia.NativeAcceptance/1", new string('a', 32), "DOMENIA", "dc.cnamts.local",
        "S-1-5-21-1-2-3-999", new string('b', 40), new string('c', 64), Target("domenia-canary", 1001), "Avant",
        Target("domenia-test-group", 1002), Target("domenia-test-pc$", 1003, "domenia-test-pc.cnamts.local"));
    private static FicheEntry Entry(NativeAcceptanceTarget target) => FicheEntry.Create(FicheKind.User, target.ObjectGuid, target.Dn, target.Sam,
        new Dictionary<string, IEnumerable<string?>> { ["objectSid"] = [target.Sid], ["sAMAccountName"] = [target.Sam],
            ["whenCreated"] = ["20261020100000.0Z"], ["userAccountControl"] = ["512"], ["description"] = ["Avant"] });
    private static WritePlan Plan(NativeAcceptanceManifest m, string? before = "Avant", string? after = "Marqueur")
    {
        var draft = new WritePlanDraft(ObjectWrites.UpdateKind, "Canari", "Description", "Recette", new("user", "Utilisateur", m.Canary.Sam, m.Canary.Dn,
            m.Canary.ObjectGuid.ToString("D"), m.Canary.Sam), [new("description", "Description", after is null ? WriteChangeKind.Clear : before is null ? WriteChangeKind.Add : WriteChangeKind.Replace,
                before, after, before, after)], [], new(false, null, "Recette explicite"), new(true, "Inverse", "Nouveau plan"), m.Controller);
        return WritePlans.Seal(draft, new string('d', 32), @"CNAMTS\operator", AppMode.Directory, Created, TimeZoneInfo.Utc);
    }

    [Test]
    public static void Native_acceptance_manifest_rejects_scope_spoofs_duplicate_identity_and_extra_properties()
    {
        var valid = Manifest(); valid.Validate();
        foreach (var dn in new[] { NativeAcceptanceManifest.Root, NativeAcceptanceManifest.Scope,
            "CN=A,OU=Domenia-Tests-Other," + NativeAcceptanceManifest.Root, "CN=A\\,OU=Domenia-Tests," + NativeAcceptanceManifest.Root,
            "CN=A,OU=Domenia-Tests,DC=elsewhere,DC=local" })
        { Check.Throws<InvalidDataException>(() => (valid with { Canary = valid.Canary with { Dn = dn } }).Validate(), "DN hors portée refusé avant connexion"); }
        Check.Throws<InvalidDataException>(() => (valid with { Group = valid.Group with { ObjectGuid = valid.Canary.ObjectGuid } }).Validate(), "identité réutilisée");
        Check.Throws<InvalidDataException>(() => (valid with { OperatorSid = valid.Canary.Sid }).Validate(), "opérateur interdit comme canari");
        var json = JsonSerializer.Serialize(valid, NativeAcceptanceManifest.Json);
        Check.Equal(valid, NativeAcceptanceManifest.Parse(json), "manifeste relu sans réseau");
        Check.Throws<InvalidDataException>(() => NativeAcceptanceManifest.Parse(json.Insert(1, "\"format\":\"Domenia.NativeAcceptance/1\",")), "clé dupliquée");
        Check.Throws<JsonException>(() => NativeAcceptanceManifest.Parse(json.Insert(1, "\"ignoreGuards\":true,")), "extension inconnue");
    }

    [Test]
    public static void Native_acceptance_target_checks_recreation_sid_creation_protection_and_controller_accounts()
    {
        var target = Manifest().Canary; var entry = Entry(target);
        NativeAcceptanceManifest.VerifyTarget(entry, target, FicheKind.User);
        var changed = new[] { entry with { ObjectGuid = Guid.NewGuid() }, entry with { Dn = "CN=A," + NativeAcceptanceManifest.Root },
            entry.With(new Dictionary<string, ImmutableArray<string>> { ["whenCreated"] = ["20261021100000.0Z"] }),
            entry.With(new Dictionary<string, ImmutableArray<string>> { ["objectSid"] = ["S-1-5-21-1-2-3-9000"] }),
            entry.With(new Dictionary<string, ImmutableArray<string>> { ["adminCount"] = ["1"] }),
            entry.With(new Dictionary<string, ImmutableArray<string>> { ["isCriticalSystemObject"] = ["TRUE"] }),
            entry.With(new Dictionary<string, ImmutableArray<string>> { ["userAccountControl"] = [AdValues.ServerTrustAccount.ToString(System.Globalization.CultureInfo.InvariantCulture)] }) };
        foreach (var value in changed) { Check.Throws<InvalidDataException>(() => NativeAcceptanceManifest.VerifyTarget(value, target, FicheKind.User), "identité modifiée ou protégée"); }
    }

    [Test]
    public static void Native_acceptance_only_admits_intact_description_canary_and_exact_inverse()
    {
        var m = Manifest(); var plan = Plan(m); var login = @"CNAMTS\operator";
        m.VerifyPlan(plan, "Avant", "Marqueur", login);
        m.VerifyPlan(Plan(m, "Marqueur", null), "Marqueur", null, login);
        m.VerifyPlan(Plan(m, null, "Marqueur"), null, "Marqueur", login);
        foreach (var value in new[] { plan with { Simulated = true }, plan with { Controller = "other.cnamts.local" },
            plan with { Target = plan.Target with { Dn = "CN=A," + NativeAcceptanceManifest.Root } },
            plan with { Changes = [plan.Changes[0] with { Attribute = "mail" }] }, plan with { Changes = [plan.Changes[0], plan.Changes[0]] } })
        { Check.Throws<InvalidDataException>(() => m.VerifyPlan(value with { Fingerprint = WritePlans.ComputeFingerprint(value) }, "Avant", "Marqueur", login), "autre action même rescellée refusée"); }
        Check.Throws<InvalidDataException>(() => m.VerifyPlan(plan, "Autre état", "Marqueur", login), "état antérieur non conforme");
        Check.Throws<InvalidDataException>(() => m.VerifyPlan(plan, "Avant", "Marqueur", "autre"), "autre opérateur");
    }
}
