using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class LoginSelectionSecurityTests
{
    [Test]
    public static async Task Assistance_actual_step_refuses_a_stale_object_stamp_before_recording_any_launch()
    {
        var bridge = new SimulatedBridge(); using var owned = bridge.Context;
        var user = (await bridge.Source.ReadLocalAsync(default)).Directory.Users.First();
        var opened = await bridge.CallAsync("assistance.subject.read", JsonSerializer.Serialize(new { dn = user.DistinguishedName }));
        Check.Equal("result", opened.Kind, "sujet réellement lu");
        var workshop = SupportWorkshop.From(owned); var known = workshop.LastRead(user.DistinguishedName)!.Value;
        Check.NotNull(known.Record.Selection, "identité détenue par l’atelier, pas seulement le JSON de page");
        var recipe = AssistanceRecipes.All.First(r => r.Steps.Any(s => s.Subject == AssistanceSubject.User && s.Action is not null));
        var step = recipe.Steps.First(s => s.Subject == AssistanceSubject.User && s.Action is not null);
        foreach (var stale in new[] { known.Record.Selection! with { ObjectGuid = Guid.NewGuid() }, known.Record.Selection! with { Sid = "S-1-other" },
            known.Record.Selection! with { Kind = "computer" }, known.Record.Selection! with { Generation = known.Record.Selection!.Generation + 1 } })
        {
            workshop.Remember(known.Record with { Selection = stale }, known.Snapshot);
            var answer = await bridge.CallAsync("assistance.step.run", JsonSerializer.Serialize(new { recipe = recipe.Id, step = step.Id, dn = user.DistinguishedName }));
            Check.Equal("error", answer.Kind, "ancienne sélection refusée par le vrai handler");
            Check.Equal("selection.changed", answer.Error!.Code, "identité divergente");
            Check.Null(workshop.Launch(user.DistinguishedName, recipe.Id, step.Id), "aucun résultat ni lancement enregistré");
        }
        workshop.Remember(known.Record, known.Snapshot);
        Check.Equal("result", (await bridge.CallAsync("assistance.step.run", JsonSerializer.Serialize(new { recipe = recipe.Id, step = step.Id, dn = user.DistinguishedName }))).Kind,
            "sélection actuelle toujours utilisable");
    }

    [Test]
    public static async Task Read_stamp_accepts_its_own_one_shot_consumption_but_refuses_an_unrelated_account_change()
    {
        var bridge = new SimulatedBridge(); using var owned = bridge.Context; var accounts = AccountAccess.From(owned);
        await accounts.OverviewAsync(default);
        accounts.RegisterRefusal(CredentialRules.Directory, "Lecture", null, "accessDenied", null, true);
        var request = (await accounts.OverviewAsync(default)).Pending.First(p => p.Scope == CredentialRules.Directory);
        using var password = PasswordSecrets.FromText("selection-fixture-only");
        Check.True((await accounts.RecoverAsync(request.Id, @"EXAMPLE\adm-s.leroy", password, LeaseMode.OneShot, 30, null, default)).Result.Success, "compte temporaire validé");
        using var outer = SelectionReadScope.Enter(owned); using var inner = SelectionReadScope.Enter(owned);
        var before = inner.Generation;
        using var read = await accounts.AcquireDirectoryReadAsync(CredentialRules.Directory, null, default);
        Check.Equal(@"EXAMPLE\adm-s.leroy", read.Account, "compte à usage unique effectivement choisi");
        Check.True(inner.Generation > before, "consommation observée à l’admission");
        Check.Equal(inner.Generation, outer.Generation, "portées imbriquées mises à jour ensemble");
        inner.RequireCurrent(); outer.RequireCurrent(); read.EnsureCurrent();
        await accounts.ForgetAllAsync(default);
        Check.Throws<DomeniaOperationException>(read.EnsureCurrent, "bail déjà consommé invalidé sans libérer prématurément sa copie");
        Check.Throws<DomeniaOperationException>(inner.RequireCurrent, "vrai changement de sélection refusé");
        await Check.ThrowsAsync<DomeniaOperationException>(async () => { using var forbidden = await accounts.AcquireDirectoryReadAsync(CredentialRules.Directory, null, default); }, "aucune acquisition tardive");
    }

    [Test]
    public static async Task Real_object_views_share_an_immutable_selection_and_reject_a_late_account_answer()
    {
        var bridge = new SimulatedBridge(); using var owned = bridge.Context;
        var user = (await bridge.Source.ReadLocalAsync(default)).Directory.Users.First();
        var dn = user.DistinguishedName;
        var fiche = await bridge.CallAsync("fiche.read", JsonSerializer.Serialize(new { dn }));
        var relations = await bridge.CallAsync("relations.subject", JsonSerializer.Serialize(new Dictionary<string, string> { ["ref"] = dn }));
        var assistance = await bridge.CallAsync("assistance.subject.read", JsonSerializer.Serialize(new { dn }));
        foreach (var answer in new[] { fiche, relations, assistance }) Check.Equal("result", answer.Kind, "vraie page sélectionnée");
        var identities = new[] { ((FicheSheet)fiche.Data!).Selection, ((RelationSubjectView)relations.Data!).Selection, ((SubjectView)assistance.Data!).Selection };
        foreach (var identity in identities)
        {
            Check.NotNull(identity, "contexte partagé présent"); Check.Equal(user.ObjectGuid, identity!.ObjectGuid, "GUID exact");
            Check.Equal(identities[0]!.Reader, identity.Reader, "même lecteur scellé sans secret");
            Check.Equal(identities[0]!.Domain, identity.Domain, "même domaine");
        }
        var source = new SwitchingSource(bridge.Source);
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
        var registry = OperationModules.CreateRegistryFromDefinitions(context,
            [new("assistance.subject.read", OperationClass.Local, (_, _, _) => { source.Epoch++; return Task.FromResult<object?>(assistance.Data); }, "Réponse tardive")], null);
        var replies = new List<BridgeResponse>(); using var dispatcher = new BridgeDispatcher(registry, replies.Add);
        await dispatcher.HandleAsync(JsonSerializer.Serialize(new { id = "changed", op = "assistance.subject.read", args = new { dn } }), default);
        Check.Equal("error", replies.Last().Kind, "ancienne sélection rejetée avant publication");
        Check.Equal("selection.changed", replies.Last().Error!.Code, "raison contrôlée");
    }

    [Test]
    public static async Task Selection_context_checks_every_identity_dimension_and_missing_identity_never_authorizes()
    {
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed());
        var session = (await source.GetSessionAsync(default)) with { Domain = new("test.local", "TEST", Fixtures.Root), StoreId = "store", Epoch = 2 };
        var target = Fixtures.Computer("PC1");
        var identity = SelectionIdentity.Capture(session, target.ObjectGuid, "computer", target.DistinguishedName, target.Name, target.SamAccountName, target.Sid, 7)!;
        Check.NotNull(identity, "identité complète");
        foreach (var other in new[] { identity with { ObjectGuid = Guid.NewGuid() }, identity with { Sid = "S-1-other" }, identity with { Kind = "user" },
            identity with { Dn = "CN=Other," + Fixtures.Root }, identity with { Epoch = 3 }, identity with { Generation = 8 }, identity with { StoreId = "other" },
            identity with { Reader = "another" }, identity with { Domain = "DC=foreign" }, identity with { Login = "OTHER$" } })
            Check.False(identity.SameContext(other), "dimension modifiée refusée");
        Check.Null(SelectionIdentity.Capture(session, Guid.Empty, "computer", target.DistinguishedName, target.Name, null, null), "pas de GUID inventé");
        Check.Null(SelectionIdentity.Capture(session, target.ObjectGuid, null, target.DistinguishedName, target.Name, null, null), "pas de type inventé");
        Check.Null(SelectionIdentity.Capture(session, target.ObjectGuid, "computer", "CN=PC,DC=foreign", target.Name, null, null), "autre domaine refusé");
    }

    [Test]
    public static async Task Remote_block_reasons_accumulate_and_the_actual_plan_boundary_never_invokes_a_provider()
    {
        var bridge = new SimulatedBridge(); using var owned = bridge.Context;
        var snapshot = (await bridge.Source.GetSessionAsync(default)) with { Connection = ConnectionState.Disconnected, Administration = AdministrationIdentity.Unknown,
            DirectoryAvailability = new(DirectoryAvailabilityState.Offline, Fixtures.Now, Fixtures.Now, 1, "Hors ligne") };
        var denied = RemoteWriteAccess.Evaluate(AppMode.Directory, snapshot, true, 1, 1, true, false, false);
        Check.False(denied.Allowed, "aucune permission supposée"); Check.Equal(8, denied.Reasons.Length, "toutes les raisons actives conservées");
        var admin = snapshot with { Connection = ConnectionState.Connected, Administration = new(AdministrationIdentityState.Administrator, "Compte confirmé"), DirectoryAvailability = DirectoryAvailabilitySnapshot.Unknown };
        Check.True(RemoteWriteAccess.Evaluate(AppMode.Directory, admin).Allowed, "lecture par défaut compatible avec un plan confirmé");
        using var context = new EngineContext(SimulatedBridge.Decision with { Mode = AppMode.Directory }, bridge.Source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
        var sent = 0;
        var registry = OperationModules.CreateRegistryFromDefinitions(context,
            [new("poste.restart.plan", OperationClass.Local, (_, _, _) => { sent++; return Task.FromResult<object?>("forbidden"); }, "Exécuteur interdit")], null);
        var replies = new List<BridgeResponse>(); using var dispatcher = new BridgeDispatcher(registry, replies.Add);
        await dispatcher.HandleAsync("""{"id":"remote","op":"poste.restart.plan","args":{"mode":"now"}}""", default);
        Check.Equal(0, sent, "refus avant lecture de préconditions ou commande native"); Check.Equal("remote.writeBlocked", replies.Last().Error!.Code, "garde moteur réel");
    }

    [Test]
    public static void Shared_secret_attributes_never_reach_a_fiche_export_plan_or_compensation()
    {
        foreach (var attribute in new[] { "unicodePwd;binary", " unicodePwd ;binary", "msDS-KeyCredentialLink;range=0-*", "msLAPS-FutureSecret", "msDS-ManagedPasswordFuture", "trustAuthIncoming", "unixUserPassword" })
        {
            Check.True(FicheAttributeRules.IsSensitive(attribute), "fiche : " + attribute);
            Check.True(ShellSecrets.IsSecretAttribute(attribute), "export : " + attribute);
            Check.True(WriteKindRules.IsSecretAttribute(attribute), "compensation : " + attribute);
            var draft = FakeWriteExecutor.Draft(); draft = draft with { Changes = [draft.Changes[0] with { Attribute = attribute, AfterValue = "synthetic-marker" }] };
            Check.Throws<ArgumentException>(() => WritePlans.Seal(draft, WritePlans.NewId(), "TEST\\operator", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc), "aucun secret dans un plan ou reçu futur");
        }
        Check.False(SecretAttributes.Contains("msLAPS-PasswordExpirationTime"), "date non secrète reste consultable");
        var password = FakeWriteExecutor.Draft() with { Changes = [new("unicodePwd", "Mot de passe", WriteChangeKind.Reset, "Jamais lu", "Nouvelle saisie", null, null)] };
        Check.NotNull(WritePlans.Seal(password, WritePlans.NewId(), "operator", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc), "réinitialisation sans valeur conservée");
    }

    [Test]
    public static void Protected_copy_bounds_are_enforced_before_the_writer_and_only_success_consumes_the_copy()
    {
        Check.False(SecretClipboardPolicy.Allows(""), "vide refusé"); Check.False(SecretClipboardPolicy.Allows("abc\0def"), "troncature native refusée");
        Check.True(SecretClipboardPolicy.Allows(new string('x', 8192)), "borne normale incluse");
        Check.False(SecretClipboardPolicy.Allows(new string('x', 8193)), "borne normale dépassée");
        Check.True(SecretClipboardPolicy.Allows(new string('1', 1024), true), "borne récupération incluse");
        Check.False(SecretClipboardPolicy.Allows(new string('1', 1025), true), "borne récupération dépassée");
        using var huge = SecretReading.FromPassword("PC1", "admin", new string('x', 8193), "test", Fixtures.Now);
        var writes = 0; Check.False(huge.CopyOnce(_ => { writes++; return true; }), "aucun appel natif hors borne"); Check.Equal(0, writes, "zéro copie");
        using var valid = SecretReading.FromPassword("PC1", "admin", "synthetic-only", "test", Fixtures.Now);
        Check.False(valid.CopyOnce(_ => false), "échec non consommé"); Check.True(valid.CopyOnce(_ => true), "une copie ensuite"); Check.False(valid.CopyOnce(_ => true), "pas de seconde copie");
    }
}
