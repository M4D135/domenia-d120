using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Explicit VM-only acceptance entry point; never discovered by the normal test runner.</summary>
internal static class NativeAcceptance
{
    internal static async Task<int> RunAsync(string[] args)
    {
        if (!OperatingSystem.IsWindows() || args.Length != 3 || args[2] is not ("--read-only" or "--canary"))
        { Console.Error.WriteLine("Usage Windows : --native-acceptance manifeste.json --read-only|--canary"); return 2; }
        try
        {
            var path = Path.GetFullPath(args[1]);
            if (new FileInfo(path).Length > 16_384) { throw new InvalidDataException("Manifeste trop long."); }
            var manifest = NativeAcceptanceManifest.Parse(await File.ReadAllTextAsync(path).ConfigureAwait(false));
            using var identity = WindowsIdentity.GetCurrent();
            var assembly = typeof(NativeAcceptance).Assembly.Location;
            var hash = Convert.ToHexStringLower(SHA256.HashData(await File.ReadAllBytesAsync(assembly).ConfigureAwait(false)));
            if (!string.Equals(Environment.MachineName, manifest.Machine, StringComparison.OrdinalIgnoreCase)
                || identity.User?.Value != manifest.OperatorSid || hash != manifest.AssemblySha256)
            { throw new InvalidDataException("VM, SID opérateur ou assemblage différents du manifeste."); }
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(local)) { throw new InvalidDataException("Dossier durable local indisponible."); }
            var root = Path.Combine(local, "Domenia", "E2E", "NativeAcceptance");
            var folder = Path.Combine(root, manifest.RunId);
            CompatibleDirectoryCache.ValidateLocalPath(Path.Combine(folder, "evidence.jsonl"));
            Directory.CreateDirectory(folder);
            // CreateNew prevents a second invocation from replaying a write after an interrupted run.
            using var evidence = new Evidence(Path.Combine(folder, "evidence.jsonl"));
            evidence.Save("manifest", new { manifest, mode = args[2], assembly, machine = Environment.MachineName });
            using var receiptStore = new FileReceiptStore(Path.Combine(root, "receipts-native-acceptance.jsonl"), SilentTechnicalJournal.Instance);
            var receiptState = await receiptStore.ReadAllAsync(CancellationToken.None).ConfigureAwait(false);
            if (receiptState.Unreadable != 0 || receiptState.Receipts.Any(WriteReceipts.IsPending))
            { throw new InvalidDataException("Reçus natifs incertains : aucune nouvelle recette exécutée."); }
            using var connection = new AdConnection(new(manifest.Controller, NativeAcceptanceManifest.Domain));
            var cache = new CompatibleDirectoryCache(Path.Combine(folder, "app"), Path.Combine(folder, "data"), NativeAcceptanceManifest.Domain, TimeProvider.System, isolated: true);
            using var source = new AdDirectorySource(NativeAcceptanceManifest.Domain, () => identity.Name, TimeProvider.System, connection: connection, localStore: cache);
            var guarded = new CanaryExecutor(source, manifest, identity.Name);
            using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Recette native explicite", null, NativeAcceptanceManifest.Domain, []),
                source, new MemoryPreferenceStore(), TimeProvider.System, SilentTechnicalJournal.Instance,
                ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]), writers: WriteExecutors.From([guarded]), receipts: receiptStore);
            using var initial = new CancellationTokenSource(TimeSpan.FromMinutes(3));
            var rootDse = await connection.RootDseAsync(initial.Token).ConfigureAwait(false);
            if (!DistinguishedName.AreEqual(rootDse.DefaultNamingContext, NativeAcceptanceManifest.Root)
                || !string.Equals(rootDse.DnsHostName, manifest.Controller, StringComparison.OrdinalIgnoreCase) || rootDse.IsSynchronized != true)
            { throw new InvalidDataException("Contrôleur, domaine ou synchronisation non confirmés."); }
            var domain = await source.DomainAsync(initial.Token).ConfigureAwait(false);
            if (!DistinguishedName.AreEqual(domain.RootDn, NativeAcceptanceManifest.Root)) { throw new InvalidDataException("Domaine étranger."); }
            var fiche = context.Readers.Require<IFicheReader>();
            var user = await ReadTarget(fiche, manifest.Canary, FicheKind.User, initial.Token).ConfigureAwait(false);
            var group = await ReadTarget(fiche, manifest.Group, FicheKind.Group, initial.Token).ConfigureAwait(false);
            var computer = await ReadTarget(fiche, manifest.Computer, FicheKind.Computer, initial.Token).ConfigureAwait(false);
            var session = await source.GetSessionAsync(initial.Token).ConfigureAwait(false);
            if (session.Account.Login != identity.Name || session.Account.Dn is null || DistinguishedName.AreEqual(session.Account.Dn, manifest.Canary.Dn)
                || !string.Equals(session.Controller?.DnsName, manifest.Controller, StringComparison.OrdinalIgnoreCase)
                || user.First("description") != manifest.OriginalDescription)
            { throw new InvalidDataException("Session ou état initial du canari différent du manifeste."); }
            evidence.Save("preflight", new { rootDse, session, user = manifest.Canary, group = manifest.Group, computer = manifest.Computer });
            if (args[2] == "--canary") { await Canary(context, manifest, fiche, evidence).ConfigureAwait(false); }
            evidence.BeforeRead = async ct =>
            {
                await ReadTarget(fiche, manifest.Canary, FicheKind.User, ct).ConfigureAwait(false);
                await ReadTarget(fiche, manifest.Group, FicheKind.Group, ct).ConfigureAwait(false);
                await ReadTarget(fiche, manifest.Computer, FicheKind.Computer, ct).ConfigureAwait(false);
            };
            await evidence.Read("directory.scope", ct => source.RefreshAsync(MeasureFamily.Directory, new(NativeAcceptanceManifest.Scope, "Domenia-Tests", true), ct)).ConfigureAwait(false);
            await Reads(context, manifest, Target(user), Target(computer), evidence).ConfigureAwait(false);
            evidence.Save("finished", new { evidence.Errors, canaryRequested = args[2] == "--canary", qualified = false,
                reason = "Retours bruts à examiner : une opération retournée ne prouve pas un résultat complet. PsExec et repli SYSTEM non sollicités par ce pilote." });
            Console.WriteLine("Preuves conservées : " + folder + ". Qualification fonctionnelle à examiner séparément.");
            return evidence.Errors == 0 ? 0 : 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Recette arrêtée : " + ex.GetType().Name + (ex is DomeniaOperationException op ? " (" + op.Code + ")" : "")
                + ". Consulter les preuves et reçus durables ; aucune relance automatique.");
            return 1;
        }
    }

    private static async Task<FicheEntry> ReadTarget(IFicheReader reader, NativeAcceptanceTarget expected, FicheKind kind, CancellationToken token)
    {
        var value = (await reader.ReadAsync(expected.Dn, token).ConfigureAwait(false)).Entry;
        NativeAcceptanceManifest.VerifyTarget(value, expected, kind); return value;
    }
    private static AuditTarget Target(FicheEntry entry) => new(entry.Dn, entry.Kind == FicheKind.User ? AuditObjectKind.User : AuditObjectKind.Computer,
        entry.Name, entry.First("sAMAccountName"), entry.ObjectGuid, entry.First("objectSid"), entry.First("dNSHostName"), entry.Int32("primaryGroupID"), entry.First("description"));
    private static async Task Canary(EngineContext context, NativeAcceptanceManifest manifest, IFicheReader reader, Evidence evidence)
    {
        var circuit = WriteCircuit.From(context); var marker = "Domenia recette " + manifest.RunId;
        var draft = await context.Writers.Require<IObjectUpdateExecutor>().PlanAsync(manifest.Canary.Dn, new Dictionary<string, string?> { ["description"] = marker }, CancellationToken.None).ConfigureAwait(false);
        var prepared = await circuit.PlanAsync(draft, CancellationToken.None).ConfigureAwait(false);
        var login = (await context.Directory.GetSessionAsync(CancellationToken.None).ConfigureAwait(false)).Account.Login;
        manifest.VerifyPlan(prepared.Plan, manifest.OriginalDescription, marker, login);
        evidence.Save("canary.plan", prepared.Plan); // Never persist the single-use token.
        var receipt = await circuit.ExecuteAsync(prepared.Plan.Id, prepared.Token, prepared.Plan.Confirmation.TypedName, null, CancellationToken.None).ConfigureAwait(false);
        evidence.Save("canary.receipt", receipt);
        RequireVerified(receipt);
        var observed = await ReadTarget(reader, manifest.Canary, FicheKind.User, CancellationToken.None).ConfigureAwait(false);
        if (observed.First("description") != marker) { throw new InvalidDataException("Valeur canari indépendante différente ; reçu conservé."); }
        var inverse = await CompensationPlanner.PlanAsync(context, receipt.Id, manifest.Canary.Dn, CancellationToken.None).ConfigureAwait(false);
        manifest.VerifyPlan(inverse.Plan, marker, manifest.OriginalDescription, login);
        evidence.Save("compensation.plan", inverse.Plan);
        var restored = await circuit.ExecuteAsync(inverse.Plan.Id, inverse.Token, inverse.Plan.Confirmation.TypedName, null, CancellationToken.None).ConfigureAwait(false);
        evidence.Save("compensation.receipt", restored); RequireVerified(restored);
        var final = await ReadTarget(reader, manifest.Canary, FicheKind.User, CancellationToken.None).ConfigureAwait(false);
        if (final.First("description") != manifest.OriginalDescription) { throw new InvalidDataException("Compensation non confirmée par lecture indépendante."); }
        evidence.Save("canary.restored", new { original = receipt.Id, compensation = restored.Id, manifest.Canary.ObjectGuid, independentRead = true });
    }
    private static void RequireVerified(ReceiptView receipt)
    {
        if (receipt.Pending || receipt.Simulated || receipt.Result != WriteResult.Applied || receipt.Verification != VerificationState.Verified)
        { throw new InvalidDataException("Écriture non confirmée ; pas de renvoi ni compensation aveugle. Reçu durable conservé."); }
    }

    private static async Task Reads(EngineContext context, NativeAcceptanceManifest m, AuditTarget user, AuditTarget computer, Evidence e)
    {
        var audit = context.Readers.Require<IAuditReader>(); var controllers = new[] { m.Controller };
        await e.Read("audit.findTarget", ct => audit.FindTargetAsync(user.Dn, ct));
        await e.Read("audit.searchObjects", ct => audit.SearchObjectsAsync(m.Canary.Sam, 10, ct));
        await e.Read("audit.domainGroup", ct => audit.FindDomainGroupAsync(512, ct));
        await e.Read("audit.overview", audit.DomainOverviewAsync);
        await e.Read("audit.localTotals", audit.LocalTotalsAsync);
        await e.Read("audit.controllers", audit.ControllersAsync);
        await e.Read("audit.probes", ct => audit.ProbeControllersAsync(controllers, null, ct));
        await e.Read("audit.services", ct => audit.ControllerServicesAsync(controllers, 15, ct));
        await e.Read("audit.compare", ct => audit.CompareObjectAsync(user, controllers, ct));
        await e.Read("audit.passwordPolicy", ct => audit.PasswordPolicyAsync(user, ct));
        await e.Read("audit.nestedGroups", ct => audit.NestedGroupsAsync(user, ct));
        await e.Read("audit.membership", ct => audit.MembershipAsync(user, m.Group.Dn, ct));
        await e.Read("audit.delegations", ct => audit.DelegationsAsync(user, ct));
        await e.Read("audit.tokenGroups", ct => audit.TokenGroupsAsync(m.Canary.Sid, ct));
        await e.Read("audit.gpoLinks", ct => audit.GpoLinksAsync([NativeAcceptanceManifest.Scope], ct));
        await e.Read("audit.appliedPolicies", ct => audit.AppliedPoliciesAsync(computer, ct));
        await e.Read("audit.machineIdentity", ct => audit.MachineIdentityAsync(computer, ct));
        await e.Read("audit.relations", ct => audit.RelationsAsync(user, ct));
        await e.Read("audit.relationHistory", ct => audit.RelationHistoryAsync(user, 10, ct));
        IdentityScanRead? scan = null;
        await e.Read("audit.identityScan", async ct => scan = await audit.IdentityScanAsync(NativeAcceptanceManifest.Scope, true, 100, ct));
        if (scan is not null) { await e.Read("audit.localNames", ct => audit.LocalNamesAsync(scan, ct)); }
        else { e.Save("audit.localNames", new { state = "NotRun", reason = "Scan absent." }); }
        var operations = context.Readers.Require<IOperationsReader>();
        await e.Read("operations.runs", operations.RunsAsync);
        await e.Read("operations.providers", operations.ProviderStatesAsync);
        await e.Read("operations.history", operations.HistoryAsync);
        await e.Read("operations.check", ct => operations.CheckDirectoryAsync(true, ct));
        var poste = context.Readers.Require<IPosteReader>();
        await e.Read("poste.inventory", ct => poste.InventoryAsync(computer.Dn, true, PosteHealthPolicy.Default, null, ct));
        await e.Read("poste.software", ct => poste.SoftwareAsync(computer.Dn, new(false, false, false), ct));
        await e.Read("poste.sessions", ct => poste.SessionsAsync(computer.Dn, ct));
        await e.Read("poste.diagnostic", ct => poste.DiagnosticAsync(computer.Dn, null, ct));
    }

    private sealed class CanaryExecutor(AdDirectorySource source, NativeAcceptanceManifest manifest, string login) : IObjectUpdateExecutor
    {
        private readonly AdObjectUpdateExecutor native = new(source);
        public string Kind => ObjectWrites.UpdateKind;
        public Task<WritePlanDraft> PlanAsync(string dn, IReadOnlyDictionary<string, string?> fields, CancellationToken token)
        {
            if (!DistinguishedName.AreEqual(dn, manifest.Canary.Dn) || fields.Count != 1 || !fields.TryGetValue("description", out var value)
                || value != manifest.OriginalDescription && value != "Domenia recette " + manifest.RunId)
            { throw new InvalidDataException("Plan hors canari refusé."); }
            return native.PlanAsync(dn, fields, token);
        }
        private async Task Guard(WritePlan plan, CancellationToken token)
        {
            var marker = "Domenia recette " + manifest.RunId; var inverse = plan.Changes.Length == 1 && plan.Changes[0].BeforeValue == marker;
            manifest.VerifyPlan(plan, inverse ? marker : manifest.OriginalDescription, inverse ? manifest.OriginalDescription : marker, login);
            await ReadTarget(new AdFicheReader(source), manifest.Canary, FicheKind.User, token).ConfigureAwait(false);
        }
        public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken token) { await Guard(plan, token); return await native.CheckAsync(plan, token); }
        public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken token) { await Guard(plan, token); return await native.ExecuteAsync(plan, token); }
        public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken token) { await Guard(plan, token); return await native.VerifyAsync(plan, token); }
    }
    private sealed class Evidence(string path) : IDisposable
    {
        private readonly FileStream stream = new(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough);
        internal int Errors { get; private set; }
        internal Func<CancellationToken, Task>? BeforeRead { get; set; }
        internal void Save(string operation, object value)
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(new { at = DateTimeOffset.UtcNow, operation, value }, Compact);
            if (bytes.Length > 2 * 1024 * 1024) { throw new InvalidDataException("Réponse trop grande pour le journal de recette."); }
            stream.Write(bytes); stream.WriteByte((byte)'\n'); stream.Flush(true);
        }
        private static readonly JsonSerializerOptions Compact = new(NativeAcceptanceManifest.Json) { WriteIndented = false };
        internal async Task Read<T>(string operation, Func<CancellationToken, Task<T>> call)
        {
            Save(operation + ".started", new { state = "Started" });
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            try
            {
                if (BeforeRead is { } guard) { await guard(timeout.Token).ConfigureAwait(false); }
                Save(operation, new { state = "Returned", qualified = false, result = await call(timeout.Token).ConfigureAwait(false) });
            }
            catch (Exception ex) when (ex is not (IOException or UnauthorizedAccessException))
            { Errors++; Save(operation, new { state = "Failed", type = ex.GetType().Name, code = (ex as DomeniaOperationException)?.Code }); }
        }
        public void Dispose() => stream.Dispose();
    }
}
