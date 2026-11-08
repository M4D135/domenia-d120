using System.Collections.Immutable;
using System.Globalization;
using System.Security;
using System.Security.Principal;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativePosteRemoteWriteTests
{
    /// <summary>Copie du compte de la session elle-même, comme l'aurait fournie AdConnection.CopyCredentialCore.</summary>
    private static AdCredentialCopy NativeRemoteSessionCredential()
    {
        var password = new SecureString();
        foreach (var character in "fixture-only") { password.AppendChar(character); }
        return new("operator", "TEST", password, tracked: true);
    }

    private sealed class Wire : IRemoteWriteBackend
    {
        internal int Sends, Reads, Disposals;
        internal string State = "Stopped";
        internal DateTimeOffset Boot = Fixtures.Now.AddDays(-1);
        internal bool FailCleanupAfterSend;
        internal bool MissingServiceAfterSend;
        internal string ConsoleSid = "S-1-5-21-1-2-3-1002";
        internal Action<RemoteWriteRequest>? BeforeSend;
        internal RemoteWriteResult Outcome = new(WriteResult.Applied, "Commande acceptée");
        public RemoteWriteSnapshot Inspect(RemoteWriteRequest request, CancellationToken token)
        {
            token.ThrowIfCancellationRequested(); Reads++;
            return new(new(request.Computer.DnsHostName!, "PC1", "PC1", "test.local"), Boot,
                request.Service is null || MissingServiceAfterSend && Sends > 0 ? null : new(request.Service, request.Service, State, State, "Manual", "Manuel", false, false, null,
                    State == "Stopped", State == "Running", State == "Running", State == "Running" ? 42 : 0, "LocalSystem", 0, [], [], false, null, null), [@"TEST\user"], false) { ConsoleUserSid = request.Run is { Interactive: true } ? ConsoleSid : null };
        }
        public RemoteWriteResult Execute(RemoteWriteRequest request)
        { BeforeSend?.Invoke(request); Sends++; if (request.Kind == PosteRemoteWrites.ServiceKind) State = request.ServiceAction == "stop" ? "Stopped" : "Running"; return Outcome; }
        public void Dispose() { Disposals++; if (FailCleanupAfterSend && Sends > 0) throw new IOException("Nettoyage natif indisponible"); }
    }
    private sealed class Fixture : IDisposable
    {
        internal readonly FixedTimeProvider Clock = TestClock.Fixed();
        internal readonly AdBoundaryTests.RecordingAdConnection Ldap = new();
        internal readonly Wire Native = new();
        internal readonly MemoryReceiptStore Receipts = new();
        internal DirectoryComputer Computer = Fixtures.Computer("PC1");
        internal readonly AdDirectorySource Source;
        internal readonly AdPosteServiceExecutor Service;
        internal readonly AdPosteRestartExecutor Restart;
        internal readonly AdPosteRestartCancelExecutor Cancel;
        internal readonly AdPosteRunExecutor Run;
        internal readonly EngineContext Context;
        internal RemoteWriteClient Client() => new(Clock) { BackendFactory = (_, _) => Native };
        internal Fixture()
        {
            Ldap.SearchAnswer = request => request.Scope == AdSearchScope.Base && DistinguishedName.AreEqual(request.BaseDn, Computer.DistinguishedName) ? [Entry(Computer)] : [];
            Source = new("test.local", () => @"TEST\operator", Clock, connection: new AdBoundaryTests.RecordingAdConnection()) { SessionCredentialCopy = NativeRemoteSessionCredential, AdministrationOverride = AdBoundaryTests.NativeAdministrator };
            Source.AdoptConnection(Ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
                Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), Source.Epoch, false);
            Service = new(Source) { ClientFactory = Client }; Restart = new(Source) { ClientFactory = Client }; Cancel = new(Source) { ClientFactory = Client }; Run = new(Source) { ClientFactory = Client };
            Context = new(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), Source, new MemoryPreferenceStore(), Clock, new RecordingJournal(),
                readers: ScreenReaders.Discover(Source, [typeof(PosteSettingsFileReader).Assembly]), writers: WriteExecutors.From([Service, Restart, Cancel, Run]), receipts: Receipts,
                configuration: RuntimeConfiguration.Read("""{"Remote":{"CommandTimeoutSeconds":23}}"""u8.ToArray(), "test"));
        }
        public void Dispose() { Context.Dispose(); Source.Dispose(); }
    }
    private static AdEntry Entry(DirectoryComputer pc)
    {
        var sid = new SecurityIdentifier(pc.Sid); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        return new(pc.DistinguishedName, new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [pc.ObjectGuid.ToByteArray()], ["objectSid"] = [bytes], ["objectClass"] = ["top", "computer"],
            ["name"] = [pc.Name], ["dNSHostName"] = [pc.DnsHostName!], ["sAMAccountName"] = [pc.SamAccountName],
            ["userAccountControl"] = [pc.UserAccountControl.ToString(CultureInfo.InvariantCulture)], ["whenCreated"] = [pc.WhenCreated.UtcDateTime.ToString("yyyyMMddHHmmss.0Z", CultureInfo.InvariantCulture)],
            ["whenChanged"] = [pc.WhenChanged.UtcDateTime.ToString("yyyyMMddHHmmss.0Z", CultureInfo.InvariantCulture)], ["primaryGroupID"] = ["515"], ["uSNChanged"] = ["1"],
        });
    }
    [Test]
    public static async Task Real_remote_executor_runs_only_after_receipt_and_confirms_service_on_same_identity()
    {
        using var f = new Fixture(); var circuit = WriteCircuit.From(f.Context);
        using var discovered = WriteExecutors.Discover(f.Source, [typeof(AdDirectorySource).Assembly]);
        foreach (var kind in new[] { "poste.restart", "poste.restartCancel", "poste.gpupdate", "poste.service", "poste.run", "poste.wake" })
            Check.NotNull(discovered.ForKind(kind), "exécuteur natif découvert : " + kind);
        f.Native.BeforeSend = request =>
        {
            Check.Equal(23, request.TimeoutSeconds, "configuration effective au fournisseur");
            Check.True(f.Receipts.ReadAllAsync(default).GetAwaiter().GetResult().Receipts.Any(r => r.Result == WriteResult.Sent), "reçu présent avant envoi réel");
        };
        var planned = await circuit.PlanAsync(await f.Service.PlanAsync(f.Computer.DistinguishedName, "Spooler", "start", default), default);
        Check.Equal(0, f.Native.Sends, "plan purement lu");
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, default);
        Check.Equal(WriteResult.Applied, receipt.Result, "envoi unique"); Check.Equal(VerificationState.Verified, receipt.Verification, "état natif relu");
        Check.Equal(1, f.Native.Sends, "pas de second transport");
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, default), "jeton consommé");
        Check.Equal(1, f.Native.Sends, "aucun rejeu");
    }
    [Test]
    public static async Task Recreated_account_or_changed_DNS_is_rejected_before_native_contact_and_expired_plan_never_sends()
    {
        foreach (var change in new[] { "guid", "sid", "dns", "disabled", "expiry" })
        {
            using var f = new Fixture(); var draft = await f.Service.PlanAsync(f.Computer.DistinguishedName, "Spooler", "start", default);
            var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, f.Clock.GetUtcNow(), TimeZoneInfo.Utc); f.Service.Bind(draft, plan);
            var reads = f.Native.Reads;
            f.Computer = change switch { "guid" => f.Computer with { ObjectGuid = Guid.NewGuid() }, "sid" => f.Computer with { Sid = Fixtures.Domain.DomainSid + "-9999" },
                "dns" => f.Computer with { DnsHostName = "other.test.local" }, "disabled" => f.Computer with { UserAccountControl = f.Computer.UserAccountControl | 2 }, _ => f.Computer };
            if (change == "expiry") f.Clock.Advance(TimeSpan.FromMinutes(6));
            try { Check.False((await f.Service.CheckAsync(plan, default)).Current, "ancienne cible refusée"); } catch (DomeniaOperationException) { }
            await Check.ThrowsAsync<DomeniaOperationException>(() => f.Service.ExecuteAsync(plan, default), "ancien plan refusé");
            Check.Equal(reads, f.Native.Reads, "aucun contact de l’homonyme"); Check.Equal(0, f.Native.Sends, "aucun envoi");
        }
    }
    [Test]
    public static async Task Restart_unknown_is_resolved_by_fresh_boot_read_from_the_sealed_receipt_without_resending()
    {
        using var f = new Fixture(); var circuit = WriteCircuit.From(f.Context);
        f.Native.Outcome = new(WriteResult.Unknown, "Réponse perdue");
        var request = PosteRemote.Restart(f.Computer.Name, "now", null, null, true).Request!;
        var planned = await circuit.PlanAsync(await f.Restart.PlanAsync(f.Computer.DistinguishedName, request, default), default);
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, planned.Plan.Confirmation.TypedName, null, default);
        Check.Equal(WriteResult.Unknown, receipt.Result, "réponse perdue explicite"); Check.True(receipt.Pending, "pas de succès inventé");
        // A fresh executor has no preparation memory or retained credential: only the sealed receipt qualifies the read.
        using var cold = new AdPosteRestartExecutor(f.Source) { ClientFactory = f.Client };
        f.Clock.Advance(TimeSpan.FromMinutes(2)); f.Native.Boot = f.Clock.GetUtcNow().AddMinutes(-1);
        Check.Equal(VerificationState.Verified, (await cold.VerifyAsync(planned.Plan, default)).State, "redémarrage postérieur au plan relu");
        f.Computer = f.Computer with { Sid = Fixtures.Domain.DomainSid + "-9999" };
        Check.Equal(VerificationState.Unknown, (await cold.VerifyAsync(planned.Plan, default)).State, "remplacement refusé même après redémarrage");
        Check.Equal(1, f.Native.Sends, "relecture uniquement");
    }
    [Test]
    public static async Task Program_arguments_stay_out_of_the_plan_and_revoked_consent_prevents_send()
    {
        using var f = new Fixture(); var consent = PosteSession.For(f.Source);
        consent.Grant(ConsentKind.Intervention, f.Computer.DistinguishedName, f.Computer.Name, 5, f.Clock.GetUtcNow(), f.Computer.ObjectGuid);
        var request = PosteRemote.Run(f.Computer.Name, "system", @"C:\Tools\Agent.exe", "opaque-argument-fixture", null, false).Request!;
        var draft = await f.Run.PlanAsync(f.Computer.DistinguishedName, request, default);
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, f.Clock.GetUtcNow(), TimeZoneInfo.Utc); f.Run.Bind(draft, plan);
        Check.False(JsonSerializer.Serialize(plan).Contains(request.Arguments, StringComparison.Ordinal), "arguments absents des preuves durables");
        consent.Revoke(ConsentKind.Intervention, f.Computer.DistinguishedName, f.Clock.GetUtcNow());
        Check.False((await f.Run.CheckAsync(plan, default)).Current, "autorisation relue avant envoi"); Check.Equal(0, f.Native.Sends, "aucun lancement");
    }
    [Test]
    public static async Task Interactive_identity_is_pinned_by_SID_and_delivery_never_becomes_a_verified_effect()
    {
        using var f = new Fixture(); var consent = PosteSession.For(f.Source);
        consent.Grant(ConsentKind.Intervention, f.Computer.DistinguishedName, f.Computer.Name, 5, f.Clock.GetUtcNow(), f.Computer.ObjectGuid);
        var run = PosteRemote.Run(f.Computer.Name, "interactive", @"C:\Tools\Tool.exe", "opaque", @"TEST\user", false).Request!;
        var draft = await f.Run.PlanAsync(f.Computer.DistinguishedName, run, default);
        Check.Equal(f.Native.ConsoleSid, draft.Changes.Single(c => c.Attribute == "remote.interactiveSid").AfterValue, "SID exact confirmé dans le plan");
        var circuit = WriteCircuit.From(f.Context); var planned = await circuit.PlanAsync(draft, default);
        f.Native.ConsoleSid = "S-1-5-21-1-2-3-9999";
        Check.False((await f.Run.CheckAsync(planned.Plan, default)).Current, "homonyme remplacé refusé");
        Check.Equal(0, f.Native.Sends, "aucun lancement pour autre SID");
        f.Native.ConsoleSid = "S-1-5-21-1-2-3-1002"; f.Native.Outcome = new(WriteResult.Delivered, "Transport terminé.");
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, planned.Plan.Confirmation.TypedName, null, default);
        Check.Equal(WriteResult.Delivered, receipt.Result, "livraison séparée de l’effet");
        Check.Equal(VerificationState.Unknown, receipt.Verification, "pas de preuve inventée de l’effet du programme");
        Check.False(receipt.Pending, "transport et nettoyage connus, sans incertitude de transport");
    }
    [Test]
    public static async Task Delivery_with_uncertain_cleanup_is_kept_unknown_and_blocks_a_new_send()
    {
        using var f = new Fixture(); var consent = PosteSession.For(f.Source);
        consent.Grant(ConsentKind.Intervention, f.Computer.DistinguishedName, f.Computer.Name, 5, f.Clock.GetUtcNow(), f.Computer.ObjectGuid);
        var run = PosteRemote.Run(f.Computer.Name, "system", @"C:\Tools\Tool.exe", "", null, false).Request!;
        var circuit = WriteCircuit.From(f.Context); var planned = await circuit.PlanAsync(await f.Run.PlanAsync(f.Computer.DistinguishedName, run, default), default);
        f.Native.Outcome = new(WriteResult.Delivered, "Fin reçue, nettoyage perdu.", false);
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, planned.Plan.Confirmation.TypedName, null, default);
        Check.Equal(WriteResult.Unknown, receipt.Result, "pas de Delivered en l’absence de nettoyage confirmé");
        Check.True(receipt.Pending, "issue retenue pour vérification"); Check.Equal(1, f.Native.Sends, "aucun rejeu");
    }

    [Test]
    public static async Task Native_cleanup_failure_cannot_turn_a_sent_command_into_a_refusal_or_an_unhandled_failure()
    {
        using var f = new Fixture(); var circuit = WriteCircuit.From(f.Context);
        var planned = await circuit.PlanAsync(await f.Service.PlanAsync(f.Computer.DistinguishedName, "Spooler", "start", default), default);
        f.Native.FailCleanupAfterSend = true;
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, default);
        Check.Equal(WriteResult.Unknown, receipt.Result, "nettoyage perdu après envoi, jamais NotApplied");
        Check.True(receipt.Pending, "reçu durable conserve l’incertitude"); Check.Equal(1, f.Native.Sends, "pas de repli ni répétition");
    }

    [Test]
    public static async Task Lost_service_acknowledgement_is_resolved_from_the_receipt_by_reading_only_the_same_service()
    {
        using var f = new Fixture(); var circuit = WriteCircuit.From(f.Context);
        f.Native.Outcome = new(WriteResult.Unknown, "Acquittement perdu");
        var planned = await circuit.PlanAsync(await f.Service.PlanAsync(f.Computer.DistinguishedName, "Spooler", "start", default), default);
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, default);
        using var cold = new AdPosteServiceExecutor(f.Source) { ClientFactory = f.Client };
        Check.Equal(VerificationState.Verified, (await cold.VerifyAsync(planned.Plan, default)).State, "Stopped vers Running relu sur l’identité scellée");
        Check.Equal(1, f.Native.Sends, "vérification sans renvoi");
        Check.Equal(WriteResult.Unknown, receipt.Result, "le reçu conserve la perte d’acquittement initiale");
    }

    [Test]
    public static async Task Missing_service_after_send_never_becomes_a_mismatch_proof()
    {
        using var f = new Fixture(); var circuit = WriteCircuit.From(f.Context);
        var planned = await circuit.PlanAsync(await f.Service.PlanAsync(f.Computer.DistinguishedName, "Spooler", "start", default), default);
        f.Native.MissingServiceAfterSend = true;
        var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, default);
        Check.Equal(VerificationState.Unknown, receipt.Verification, "absence de relecture ne prouve pas un écart");
        Check.Equal(1, f.Native.Sends, "jamais renvoyée");
    }

    [Test]
    public static async Task Only_linked_acknowledged_restart_can_be_explicitly_cancelled_while_its_boot_is_pending()
    {
        using var f = new Fixture(); var circuit = WriteCircuit.From(f.Context);
        var request = PosteRemote.Restart(f.Computer.Name, "delayed", 5, "Test", true).Request!;
        var start = await circuit.PlanAsync(await f.Restart.PlanAsync(f.Computer.DistinguishedName, request, default), default);
        var receipt = await circuit.ExecuteAsync(start.Plan.Id, start.Token, null, null, default);
        Check.True(receipt.Pending, "le redémarrage accepté attend encore une preuve de boot");
        var cancel = await circuit.PlanAsync(await f.Cancel.PlanAsync(f.Computer.DistinguishedName, default), default);
        var durable = (await f.Receipts.ReadAllAsync(default)).Receipts.Single();
        Check.False(WriteReceiptStates.BlocksWrite(durable, cancel.Plan), "annulation explicitement liée admise");
        var other = cancel.Plan with { Changes = cancel.Plan.Changes.Where(c => c.Attribute != "remote.cancelPlan").ToImmutableArray() };
        Check.True(WriteReceiptStates.BlocksWrite(durable, other), "annulation générique interdite");
        Check.True(WriteReceiptStates.BlocksWrite(durable with { Result = WriteResult.Unknown }, cancel.Plan), "acquittement initial indispensable");
        var link = cancel.Plan.Changes.Single(c => c.Attribute == "remote.cancelPlan");
        foreach (var invalid in new[] { cancel.Plan with { Operator = "autre" }, cancel.Plan with { Controller = "dc-inconnu" },
            cancel.Plan with { Simulated = !cancel.Plan.Simulated }, cancel.Plan with { Mode = "autre" },
            cancel.Plan with { Changes = [link, link] }, cancel.Plan with { Changes = [link with { AfterValue = "inconnue" }] } })
            Check.True(WriteReceiptStates.BlocksWrite(durable, invalid), "la moindre divergence retient le reçu initial");
        Check.True(WriteReceiptStates.BlocksWrite(durable with { Plan = durable.Plan with
            { Reversibility = durable.Plan.Reversibility with { Reversible = false } } }, cancel.Plan), "annulation exige un redémarrage différé réversible");
        var session = await f.Source.GetSessionAsync(default);
        var preview = await circuit.RemotePendingAsync(session, f.Computer.DistinguishedName, default);
        Check.Equal(0, preview.CancelPending, "l’interface propose l’annulation réellement connue de la session");
        f.Native.Outcome = new(WriteResult.Delivered, "Annulation acceptée");
        var cancelled = await circuit.ExecuteAsync(cancel.Plan.Id, cancel.Token, null, null, default);
        Check.Equal(WriteResult.Delivered, cancelled.Result, "annulation distincte conservée");
        Check.Equal(2, f.Native.Sends, "un redémarrage et une annulation explicite");
        Check.Equal(1, (await circuit.RemotePendingAsync(session, f.Computer.DistinguishedName, default)).CancelPending,
            "l’interface ne réoffre pas une annulation déjà consommée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => f.Cancel.PlanAsync(f.Computer.DistinguishedName, default), "annulation non réutilisable");
    }

}
