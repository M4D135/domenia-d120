using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>Sealed, session-owned native intervention. A selected one-use account belongs to the whole preparation and
/// confirmation, never to a second cascade. No durable receipt contains program arguments or credentials.</summary>
public abstract class AdPosteRemoteExecutor(AdDirectorySource source) : IWriteExecutor, IWritePlanBinder, IDisposable
{
    private protected AdDirectorySource Source => source;
    public abstract string Kind { get; }
    internal Func<RemoteWriteClient>? ClientFactory { get; init; }
    private RemoteWriteClient Client() => ClientFactory?.Invoke() ?? new(source.Clock);
    private readonly object gate = new();
    private readonly Dictionary<WritePlanDraft, Prepared> drafts = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<string, Prepared> bound = new(StringComparer.Ordinal);
    private ITimer? expiry;
    private bool disposed;
    private readonly List<(Prepared Owner, Task Completion)> retirements = [];
    private sealed class Prepared(RemoteWriteRequest request, SessionSnapshot session, AdReadAccess directory,
        AdWorkstationAccess? access, PosteConfiguration settings, RemoteWriteSnapshot? before, DateTimeOffset expires)
    {
        internal RemoteWriteRequest Request = request;
        internal readonly WritePlanOrigin Origin = WritePlanOrigin.From(session);
        internal readonly string Operator = session.Account.Login;
        internal readonly string? Controller = session.Controller?.DnsName;
        internal readonly AdReadAccess Directory = directory;
        internal readonly AdWorkstationAccess? Access = access;
        internal readonly PosteConfiguration Settings = settings;
        internal readonly RemoteWriteSnapshot? Before = before;
        internal readonly DateTimeOffset Expires = expires;
        internal WritePlan? Plan;
        internal bool InUse, Executed, Checked, RetirementStarted, VerificationTaken;
        internal WriteVerification Verification = new(VerificationState.Unknown, "Aucun effet vérifié.");
        internal void Release()
        {
            Request = Request with { Run = null };
            try { Access?.Dispose(); } finally { Directory.Dispose(); }
        }
    }
    private sealed record PendingRestart(long Epoch, DateTimeOffset At, string PlanId, string Fingerprint);
    private static readonly ConditionalWeakTable<AdDirectorySource, Dictionary<Guid, PendingRestart>> Restarts = new();
    private PendingRestart Scheduled(DirectoryComputer pc)
    {
        var known = Restarts.GetOrCreateValue(source); lock (known)
        {
            if (known.TryGetValue(pc.ObjectGuid, out var row) && row.Epoch == source.Epoch && row.At > source.Clock.GetUtcNow()) return row;
            throw WriteErrors.Refusal(WriteErrors.Stale, "Aucun redémarrage différé envoyé et encore en attente dans cette session.");
        }
    }

    protected bool OwnsPendingRestartPlan(WritePlan original)
    {
        if (!Guid.TryParse(original.Target.ObjectGuid, out var id) || !Restarts.TryGetValue(source, out var known)) return false;
        lock (known)
            return known.TryGetValue(id, out var pending) && pending.Epoch == source.Epoch && pending.At > source.Clock.GetUtcNow()
                && pending.PlanId == original.Id && pending.Fingerprint == original.Fingerprint;
    }

    private WritePlanDraft CancelDraft(DirectoryComputer pc)
    {
        var known = Scheduled(pc);
        var draft = PosteRemoteWrites.RestartCancel(pc, known.At, TimeZoneInfo.Local);
        return draft with { Changes = draft.Changes.Add(new("remote.cancelPlan", "Redémarrage à annuler", WriteChangeKind.Clear,
            "Demande acquittée dans cette session", "Annulation explicite", known.PlanId, known.Fingerprint)) };
    }

    private protected async Task<WritePlanDraft> PrepareAsync(string dn, RestartRequest? restart, RunRequest? run,
        string? service, string? action, CancellationToken token)
    {
        using var requirements = OperationCredentialScope.Enter(OperationCredentialNeeds.ForWrite(Kind));
        AdFicheObjects.ValidateDn(dn);
        _ = await source.DomainAsync(token).ConfigureAwait(false);
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        RemoteWriteAccess.Evaluate(AppMode.Directory, session).Require();
        using var identityLease = source.AcquireWriteLease(session);
        AdReadAccess? directory = null; AdWorkstationAccess? access = null;
        try
        {
            directory = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, dn, token).ConfigureAwait(false);
            var pc = await ReadComputer(directory, dn, null, token).ConfigureAwait(false);
            var settings = await RemoteCollectionSettings.EffectiveAsync(source.AccountContext, token).ConfigureAwait(false);
            if (restart is not null)
            {
                var normalized = PosteRemote.Restart(pc.Name, restart.Now ? "now" : "delayed", restart.Minutes, restart.Message, settings.Options.UseWinRm);
                if (!normalized.Check.Valid) throw WriteErrors.Refusal(PosteErrors.Refused, normalized.Check.Reason);
                restart = normalized.Request;
            }
            if (run is not null)
            {
                var normalized = PosteRemote.Run(pc.Name, run.Interactive ? "interactive" : "system", run.Command, run.Arguments, run.RunUser, run.Elevated);
                if (!normalized.Check.Valid) throw WriteErrors.Refusal(PosteErrors.Refused, normalized.Check.Reason);
                run = normalized.Request;
            }
            var request = new RemoteWriteRequest(Kind, pc, Guid.NewGuid(), settings.CommandTimeoutSeconds)
                { Restart = restart, Run = run, Service = service, ServiceAction = action, Wake = Kind == PosteRemoteWrites.WakeKind ? Wake(pc, settings) : null };
            RemoteWriteClient.Validate(request);
            if (Kind != PosteRemoteWrites.WakeKind && !settings.UseCim) throw WriteErrors.Refusal(PosteErrors.Refused, "CIM désactivé : identité Windows non vérifiable pour cette intervention.");
            RequireConsent(request);
            if ((Kind is PosteRemoteWrites.GpUpdateKind or PosteRemoteWrites.RestartCancelKind || restart is { Now: false }) && !settings.Options.UseWinRm)
                throw WriteErrors.Refusal(PosteErrors.Refused, "WinRM est désactivé ; aucune autre méthode n’est essayée.");
            RemoteWriteSnapshot? before = null;
            if (Kind != PosteRemoteWrites.WakeKind)
            {
                access = await AdWorkstationAccess.AcquireAsync(source, pc.DnsHostName!, token).ConfigureAwait(false);
                await access.BeforeContactAsync(source, pc.DnsHostName!, token).ConfigureAwait(false);
                before = await Inspect(access, request, settings, token).ConfigureAwait(false);
                access.EnsureCurrent(); ConfirmNative(request, before);
                if (run is { Interactive: true }) request = request with { RunUserSid = before.ConsoleUserSid };
            }
            directory.EnsureCurrent(); token.ThrowIfCancellationRequested();
            var now = source.Clock.GetUtcNow();
            var draft = Kind switch
            {
                PosteRemoteWrites.RestartKind => PosteRemoteWrites.Restart(pc, restart!, new(before!.SessionsComplete, before.Sessions.Length, before.Sessions,
                    before.SessionsComplete ? "Sessions relues." : "Liste des sessions non exhaustive ; des travaux peuvent être ouverts."), before.LastBoot, now, TimeZoneInfo.Local),
                PosteRemoteWrites.RestartCancelKind => CancelDraft(pc),
                PosteRemoteWrites.GpUpdateKind => PosteRemoteWrites.GpUpdate(pc),
                PosteRemoteWrites.ServiceKind => PosteRemoteWrites.Service(pc, before!.Service ?? throw new InvalidDataException("Service non lu."), action!),
                PosteRemoteWrites.RunKind => PosteRemoteWrites.Run(pc, run!, PosteSession.For(source).State(dn, now).Intervention.Until ?? now, TimeZoneInfo.Local),
                PosteRemoteWrites.WakeKind => PosteRemoteWrites.Wake(pc, request.Wake!, null, TimeZoneInfo.Local),
                _ => throw new InvalidOperationException("Action distante inconnue."),
            };
            draft = draft with { Changes = draft.Changes.Add(new("remote.identity", "Identité de relecture", WriteChangeKind.Replace,
                "GUID, SID et DNS qualifiés", "Même identité requise", pc.Sid, pc.DnsHostName)).Add(new("remote.created", "Naissance de l’objet", WriteChangeKind.Replace,
                "Date AD qualifiée", "Même naissance requise", pc.WhenCreated.ToString("O", CultureInfo.InvariantCulture), request.TimeoutSeconds.ToString(CultureInfo.InvariantCulture))), Origin = WritePlanOrigin.From(session), Controller = session.Controller?.DnsName,
                Risks = draft.Risks.Add(new(Tone.Info, "Méthode fixée : " + Method(request, settings) + ". Aucun repli ni renvoi automatique ; délai par appel " + request.TimeoutSeconds + " s.")) };
            if (request.RunUserSid is { } userSid) draft = draft with { Changes = draft.Changes.Add(new("remote.interactiveSid", "Compte de session", WriteChangeKind.Replace, "SID qualifié", "Même compte requis", userSid, userSid)) };
            lock (gate)
            {
                Purge(); ObjectDisposedException.ThrowIf(disposed, this);
                if (drafts.Count + bound.Count + retirements.Count >= WriteCircuit.PlanCapacity || source.Epoch != session.Epoch) throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée ou trop de plans préparés.");
                drafts.Add(draft, new(request, session, directory, access, settings, before, now + WritePlans.Lifetime));
                expiry ??= source.Clock.CreateTimer(_ => { try { lock (gate) Purge(); } catch (Exception) { Notice("Expiration de plans distants non aboutie ; plans conservés."); } }, null, TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));
                directory = null; access = null;
            }
            return draft;
        }
        finally { access?.Dispose(); directory?.Dispose(); }
    }

    private async Task<RemoteWriteSnapshot> Inspect(AdWorkstationAccess access, RemoteWriteRequest request, PosteConfiguration settings, CancellationToken token)
    {
        try { return await Client().InspectAsync(request, access.Credential, settings, token).ConfigureAwait(false); }
        catch (RemoteWriteAccessException ex)
        {
            access.Refused(request.Computer.DnsHostName!, Kind, ex.AuthenticationRejected);
            throw new DomeniaOperationException(ex.AuthenticationRejected ? "account.rejected" : "access.denied", ex.Message);
        }
    }
    internal static bool SameSettings(PosteConfiguration a, PosteConfiguration b) => RemoteCollectionSettings.From(a) == RemoteCollectionSettings.From(b)
        && a.CommandTimeoutSeconds == b.CommandTimeoutSeconds && a.Options.WakeOnLan == b.Options.WakeOnLan
        && a.Options.WakeNetworks.SequenceEqual(b.Options.WakeNetworks, StringComparer.Ordinal);
    private static string Method(RemoteWriteRequest request, PosteConfiguration settings) => request.Kind switch
    {
        PosteRemoteWrites.WakeKind => "UDP 9, sans identifiant", PosteRemoteWrites.RunKind => "Planificateur Windows, tâche unique",
        PosteRemoteWrites.GpUpdateKind or PosteRemoteWrites.RestartCancelKind => "WinRM",
        PosteRemoteWrites.RestartKind when !request.Restart!.Now => "WinRM",
        _ => settings.SelectedCimTransport == InventoryTransport.WinRm ? "WinRM" : "CIM/DCOM",
    };
    private static void ConfirmNative(RemoteWriteRequest request, RemoteWriteSnapshot snapshot)
    {
        if (!WorkstationIdentity.Matches(request.Computer, snapshot.Identity.Name, snapshot.Identity))
            throw WriteErrors.Refusal(WriteErrors.Stale, "L’identité Windows ne correspond plus au poste AD.");
        if (request.Run is { Interactive: true } run && (!snapshot.Sessions.Contains(run.RunUser!, StringComparer.OrdinalIgnoreCase)
            || snapshot.ConsoleUserSid is null || request.RunUserSid is { } expected && snapshot.ConsoleUserSid != expected))
            throw WriteErrors.Refusal(PosteErrors.Refused, "La session interactive qualifiée n’est pas confirmée ; aucun lancement.");
    }
    private void RequireConsent(RemoteWriteRequest request)
    {
        if (request.Kind == PosteRemoteWrites.RunKind && !PosteSession.For(source).Covers(ConsentKind.Intervention,
            request.Computer.DistinguishedName, source.Clock.GetUtcNow(), request.Computer.ObjectGuid))
            throw WriteErrors.Refusal(PosteErrors.ConsentRequired, PosteErrors.ConsentRequiredMessage);
    }
    private WakeDecision Wake(DirectoryComputer pc, PosteConfiguration settings)
    {
        if (!source.FleetDetails.Inventories.TryGetValue(pc.ObjectGuid, out var inventory)
            || !WorkstationIdentity.Matches(pc, inventory.ReportedName, inventory.HostIdentity)
            || inventory.CollectedAt > source.Clock.GetUtcNow() || source.Clock.GetUtcNow() - inventory.CollectedAt > TimeSpan.FromDays(1))
            throw WriteErrors.Refusal(PosteErrors.Refused, "Inventaire réseau confirmé de moins de 24 heures requis pour le réveil.");
        var choices = inventory.Network.Where(n => n.Physical).SelectMany(n => n.Ipv4.Select(ip =>
            PosteRemote.Wake(settings.Options.WakeOnLan, settings.Options.WakeNetworks, n.Mac, ip, n.PrefixLength))).Where(d => d.Allowed).Distinct().Take(2).ToArray();
        if (choices.Length != 1) throw WriteErrors.Refusal(PosteErrors.Refused, "Carte ou sous-réseau de réveil absent, interdit ou ambigu.");
        return choices[0];
    }
    private async Task<DirectoryComputer> ReadComputer(AdReadAccess directory, string dn, DirectoryComputer? expected, CancellationToken token)
    {
        var rows = await directory.SearchAsync(new(dn, "(objectClass=computer)", AdSearchScope.Base, [.. AdDirectoryMapper.ComputerAttributes, "objectClass"])
            { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10), ExpandRanges = true }, token).ConfigureAwait(false);
        var pc = rows.Count == 1 && rows[0].Int("userAccountControl") is not null && rows[0].Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase) ? AdDirectoryMapper.Computer(rows[0]) : null;
        if (pc is null || !DistinguishedName.AreEqual(pc.DistinguishedName, dn) || pc.WhenCreated == DateTimeOffset.MinValue || pc.WhenCreated > source.Clock.GetUtcNow()
            || pc.Sid is null || WorkstationIdentity.ExpectedName(pc) is null || pc.LegacyIndexOnly || AdValues.IsDisabled(pc.UserAccountControl) || (pc.UserAccountControl & AdValues.ServerTrustAccount) != 0
            || expected is not null && (pc.ObjectGuid != expected.ObjectGuid || pc.Sid != expected.Sid || pc.WhenCreated != expected.WhenCreated
                || !string.Equals(pc.DnsHostName, expected.DnsHostName, StringComparison.OrdinalIgnoreCase) || !string.Equals(pc.SamAccountName, expected.SamAccountName, StringComparison.OrdinalIgnoreCase)))
            throw WriteErrors.Refusal(WriteErrors.Stale, "Compte ordinateur absent, protégé ou d’identité différente ; aucun contact distant.");
        directory.EnsureCurrent(); return pc;
    }

    public void Bind(WritePlanDraft draft, WritePlan plan)
    {
        lock (gate)
        {
            Purge();
            if (!drafts.TryGetValue(draft, out var data) || plan.Kind != Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsIntact(plan)
                || !WritePlans.IsPlanId(plan.Id) || plan.Operator != data.Operator || plan.Controller != draft.Controller || plan.Target != draft.Target
                || !plan.Changes.SequenceEqual(draft.Changes) || plan.Confirmation != draft.Confirmation || bound.ContainsKey(plan.Id) || plan.ExpiresAt <= source.Clock.GetUtcNow() || plan.ExpiresAt > source.Clock.GetUtcNow() + WritePlans.Lifetime)
                throw WriteErrors.Refusal(WriteErrors.Stale, "Plan distant non lié à sa préparation.");
            data.Plan = plan; bound.Add(plan.Id, data); drafts.Remove(draft);
        }
    }
    private Prepared Recall(WritePlan plan, SessionSnapshot session)
    {
        Purge();
        if (!bound.TryGetValue(plan.Id, out var data) || data.Plan?.Fingerprint != plan.Fingerprint || !WritePlans.IsIntact(plan)
            || !data.Origin.Matches(session) || plan.ExpiresAt <= source.Clock.GetUtcNow() || data.Executed || data.InUse)
            throw WriteErrors.Refusal(WriteErrors.Stale, "Plan absent, expiré, déjà envoyé ou d’une autre session.");
        data.InUse = true; return data;
    }
    private async Task CheckCurrent(Prepared data, CancellationToken token)
    {
        data.Directory.EnsureCurrent();
        _ = await ReadComputer(data.Directory, data.Request.Computer.DistinguishedName, data.Request.Computer, token).ConfigureAwait(false);
        var settings = await RemoteCollectionSettings.EffectiveAsync(source.AccountContext, token).ConfigureAwait(false);
        if (!SameSettings(settings, data.Settings)) throw WriteErrors.Refusal(WriteErrors.Stale, "Réglages distants modifiés ; préparez un nouveau plan.");
        RequireConsent(data.Request);
        if (data.Access is { } access)
        {
            await access.BeforeContactAsync(source, data.Request.Computer.DnsHostName!, token).ConfigureAwait(false);
            var now = await Inspect(access, data.Request, data.Settings, token).ConfigureAwait(false);
            access.EnsureCurrent(); ConfirmNative(data.Request, now);
            if (data.Request.Kind == PosteRemoteWrites.ServiceKind && (now.Service?.State != data.Before?.Service?.State || now.Service?.StartMode != data.Before?.Service?.StartMode))
                throw WriteErrors.Refusal(WriteErrors.Stale, "État du service modifié depuis la préparation.");
        }
        else if (Wake(data.Request.Computer, settings) != data.Request.Wake) throw WriteErrors.Refusal(WriteErrors.Stale, "Carte ou réseau de réveil changé.");
        if (data.Request.Kind == PosteRemoteWrites.RestartCancelKind)
        {
            var known = Scheduled(data.Request.Computer);
            var link = data.Plan?.Changes.SingleOrDefault(c => c.Attribute == "remote.cancelPlan");
            if (link is null || link.BeforeValue != known.PlanId || link.AfterValue != known.Fingerprint)
                throw WriteErrors.Refusal(WriteErrors.Stale, "Le redémarrage programmé a changé ; aucune annulation envoyée.");
        }
        data.Directory.EnsureCurrent();
    }
    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        using var needs = OperationCredentialScope.Enter(OperationCredentialNeeds.ForWrite(Kind));
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = source.AcquireWriteLease(session); Prepared data;
        lock (gate) data = Recall(plan, session);
        try { RemoteWriteAccess.Evaluate(AppMode.Directory, session).Require(); await CheckCurrent(data, cancellationToken).ConfigureAwait(false);
            data.Checked = true; return WritePrecheck.Valid("GUID, SID, DNS, compte et état natif requalifiés ; même bail conservé."); }
        catch (DomeniaOperationException ex) { return WritePrecheck.Stale(ex.Message); }
        finally { lock (gate) data.InUse = false; }
    }
    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        using var needs = OperationCredentialScope.Enter(OperationCredentialNeeds.ForWrite(Kind));
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = source.AcquireWriteLease(session); Prepared data;
        lock (gate) { data = Recall(plan, session); if (!data.Checked) { data.InUse = false; throw WriteErrors.Refusal(WriteErrors.Stale, "Contrôle préalable absent."); } }
        var attempted = false;
        try
        {
            RemoteWriteAccess.Evaluate(AppMode.Directory, session).Require();
            await CheckCurrent(data, cancellationToken).ConfigureAwait(false);
            lock (gate) { data.Executed = true; } attempted = true;
            var result = await Client().ExecuteAsync(data.Request, data.Access?.Credential, data.Settings).ConfigureAwait(false);
            if (result.Failure is OperationFailureKind.AccessDenied or OperationFailureKind.LogonFailure or OperationFailureKind.AccountLocked or OperationFailureKind.AccountUnavailable)
                data.Access?.Refused(data.Request.Computer.DnsHostName!, Kind, result.Failure != OperationFailureKind.AccessDenied);
            if (result.Result == WriteResult.Applied && Kind == PosteRemoteWrites.RestartKind && data.Request.Restart is { Now: false } restart)
            {
                var known = Restarts.GetOrCreateValue(source); lock (known)
                { foreach (var old in known.Where(p => p.Value.At <= source.Clock.GetUtcNow() || p.Value.Epoch != source.Epoch).Select(p => p.Key).ToArray()) known.Remove(old);
                    if (known.Count < 32) known[data.Request.Computer.ObjectGuid] = new(source.Epoch, source.Clock.GetUtcNow().AddSeconds(restart.DelaySeconds), plan.Id, plan.Fingerprint); }
            }
            if (result.Result == WriteResult.Delivered && Kind == PosteRemoteWrites.RestartCancelKind)
            { var known = Restarts.GetOrCreateValue(source); lock (known) known.Remove(data.Request.Computer.ObjectGuid); }
            if (result.Result == WriteResult.Delivered && !result.CleanupConfirmed)
                result = result with { Result = WriteResult.Unknown, Detail = "Commande acquittée mais nettoyage non confirmé ; reçu à vérifier." };
            data.Verification = await ReadEffect(data, result).ConfigureAwait(false);
            return new(result.Result, result.Detail);
        }
        catch (Exception ex) when (attempted && ex is not OutOfMemoryException and not StackOverflowException)
        { data.Verification = new(VerificationState.Unknown, "Réponse ou relecture interrompue ; aucun renvoi autorisé."); return new(WriteResult.Unknown, "Issue distante inconnue après tentative ; vérifier le reçu avant toute autre intervention."); }
        finally
        {
            lock (gate) { data.InUse = false; if (attempted) { Retire(data); data.Executed = true; } }
        }
    }
    private async Task<WriteVerification> ReadEffect(Prepared data, RemoteWriteResult result)
    {
        if (result.Result != WriteResult.Applied || !result.CleanupConfirmed) return new(VerificationState.Unknown, result.Detail);
        if (Kind != PosteRemoteWrites.ServiceKind) return new(VerificationState.Unknown, Kind == PosteRemoteWrites.RunKind
            ? "Tâche lancée puis retirée ; effet du programme non vérifiable." : "Demande acceptée ; effet distant non encore vérifié.");
        if (data.Access is not { } access) return new(VerificationState.Unknown, "Accès poste absent ; état du service non relu ; aucune preuve d’effet.");
        var now = await Inspect(access, data.Request, data.Settings, CancellationToken.None).ConfigureAwait(false);
        access.EnsureCurrent(); ConfirmNative(data.Request, now);
        if (!KnownServiceState(now.Service?.State)) return new(VerificationState.Unknown, "État du service non relu ; aucune preuve d’effet.");
        var expected = data.Request.ServiceAction == "stop" ? "Stopped" : "Running";
        return new(now.Service?.State == expected ? VerificationState.Verified : VerificationState.Mismatch,
            now.Service?.State == expected ? "Commande acquittée et état attendu relu sur le même poste." : "Service relu dans un état différent ou inconnu.");
    }
    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (bound.TryGetValue(plan.Id, out var data) && data.Plan?.Fingerprint == plan.Fingerprint && WritePlans.IsIntact(plan)
                && data.Executed && !data.InUse && !data.VerificationTaken && data.Verification.State != VerificationState.Unknown)
            { data.VerificationTaken = true; return data.Verification; }
        }
        if (Kind is not (PosteRemoteWrites.RestartKind or PosteRemoteWrites.ServiceKind) || plan.Kind != Kind || plan.Simulated || !WritePlans.IsIntact(plan)
            || plan.Mode != AppInfoBuilder.DirectoryModeText || !Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var guid))
            return new(VerificationState.Unknown, "Effet non relisible automatiquement ; une revue manuelle documentée du reçu reste possible. Aucun envoi rejoué.");
        var identity = plan.Changes.Where(c => c.Attribute == "remote.identity").ToArray();
        var created = plan.Changes.Where(c => c.Attribute == "remote.created").ToArray();
        if (identity is not [var proof] || created is not [var birth]
            || !DateTimeOffset.TryParseExact(birth.BeforeValue, "O", CultureInfo.InvariantCulture, DateTimeStyles.None, out var born))
            return new(VerificationState.Unknown, "Preuve d’identité absente ; revue manuelle requise.");
        DateTimeOffset oldBoot = default; string? serviceName = null, serviceState = null;
        if (Kind == PosteRemoteWrites.RestartKind)
        {
            var boots = plan.Changes.Where(c => c.Attribute == "shutdown").ToArray();
            if (boots is not [var shutdown] || !DateTimeOffset.TryParseExact(shutdown.BeforeValue, "O", CultureInfo.InvariantCulture, DateTimeStyles.None, out oldBoot))
                return new(VerificationState.Unknown, "Ancienne date de démarrage absente ; revue manuelle requise.");
        }
        else
        {
            var services = plan.Changes.Where(c => c.Attribute.StartsWith("service:", StringComparison.Ordinal)).ToArray();
            if (services is not [var change] || !PosteServices.IsValidName(change.Attribute[8..])
                || change.BeforeValue is not ("Stopped" or "Running") || change.AfterValue is not ("Stopped" or "Running")
                || change.BeforeValue == change.AfterValue)
                return new(VerificationState.Unknown, "État initial/final insuffisant : une simple présence en cours ne prouve pas un redémarrage de service. Revue manuelle requise.");
            serviceName = change.Attribute[8..]; serviceState = change.AfterValue;
        }
        using var needs = OperationCredentialScope.Enter(OperationCredentialNeeds.ForWrite(Kind));
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = source.AcquireWriteLease(session);
        using var directory = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, plan.Target.Dn, cancellationToken).ConfigureAwait(false);
        var pc = await ReadComputer(directory, plan.Target.Dn, null, cancellationToken).ConfigureAwait(false);
        if (pc.ObjectGuid != guid || pc.Sid != proof.BeforeValue || pc.WhenCreated != born || !string.Equals(pc.DnsHostName, proof.AfterValue, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(pc.SamAccountName, plan.Target.SamAccountName, StringComparison.OrdinalIgnoreCase))
            return new(VerificationState.Unknown, "Poste remplacé ou déplacé ; aucun autre objet n’est contacté.");
        using var access = await AdWorkstationAccess.AcquireAsync(source, pc.DnsHostName!, cancellationToken).ConfigureAwait(false);
        await access.BeforeContactAsync(source, pc.DnsHostName!, cancellationToken).ConfigureAwait(false);
        var request = new RemoteWriteRequest(Kind, pc, Guid.NewGuid(), access.Settings.CommandTimeoutSeconds)
            { Restart = Kind == PosteRemoteWrites.RestartKind ? PosteRemote.Restart(pc.Name, "now", null, null, true).Request : null,
                Service = serviceName, ServiceAction = serviceState is null ? null : serviceState == "Running" ? "start" : "stop" };
        var current = await Inspect(access, request, access.Settings, cancellationToken).ConfigureAwait(false);
        access.EnsureCurrent(); directory.EnsureCurrent(); ConfirmNative(request, current);
        if (Kind == PosteRemoteWrites.ServiceKind)
            return current.Service is { } state && KnownServiceState(state.State) ? new(state.State == serviceState ? VerificationState.Verified : VerificationState.Mismatch,
                state.State == serviceState ? "État final du service relu sur le même poste ; aucune commande renvoyée." : "État du service différent de celui demandé.")
                : new(VerificationState.Unknown, "État du service non relu ; aucune commande renvoyée.");
        return current.LastBoot is { } next && next > oldBoot && next >= plan.CreatedAt && next <= source.Clock.GetUtcNow()
            ? new(VerificationState.Verified, "Nouveau démarrage relu après le plan sur le même GUID, SID et nom DNS.")
            : new(VerificationState.Unknown, "Aucun nouveau démarrage confirmé ; commande jamais rejouée.");
    }
    // Removal is local under the gate. Native disposal runs elsewhere and remains owned/bounded until it really returns.
    private void Notice(string message) { try { source.AccountContext?.Log.Warning(message); } catch (Exception) { } }
    private static bool KnownServiceState(string? state) => state is "Running" or "Stopped" or "Start Pending" or "Stop Pending" or "Continue Pending" or "Pause Pending" or "Paused";
    private void Retire(Prepared data)
    {
        if (data.RetirementStarted) return;
        data.RetirementStarted = true;
        data.Request = data.Request with { Run = null };
        var completion = Task.Run(() =>
        {
            try { data.Release(); }
            catch (Exception)
            { Notice("Intervention distante : nettoyage du bail non confirmé ; propriétaire retenu."); throw; }
        });
        _ = completion.ContinueWith(t => { _ = t.Exception; }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        retirements.Add((data, completion));
    }
    private void Purge()
    {
        retirements.RemoveAll(r => r.Completion.IsCompletedSuccessfully);
        var now = source.Clock.GetUtcNow();
        foreach (var key in drafts.Where(p => p.Value.Expires <= now || p.Value.Origin.Epoch != source.Epoch).Select(p => p.Key).ToArray()) { Retire(drafts[key]); drafts.Remove(key); }
        foreach (var key in bound.Where(p => !p.Value.InUse && (p.Value.Expires <= now || p.Value.Origin.Epoch != source.Epoch || disposed)).Select(p => p.Key).ToArray()) { Retire(bound[key]); bound.Remove(key); }
    }
    public void Dispose() { lock (gate) { disposed = true; expiry?.Dispose(); expiry = null; foreach (var data in drafts.Values) Retire(data); drafts.Clear(); Purge(); } }
}

public sealed class AdPosteRestartExecutor(AdDirectorySource source) : AdPosteRemoteExecutor(source), IPosteRestartExecutor
{
    public override string Kind => PosteRemoteWrites.RestartKind;
    public Task<WritePlanDraft> PlanAsync(string dn, RestartRequest request, CancellationToken cancellationToken) => PrepareAsync(dn, request, null, null, null, cancellationToken);
}
public sealed class AdPosteRestartCancelExecutor(AdDirectorySource source) : AdPosteRemoteExecutor(source), IPosteRestartCancelExecutor
{
    public override string Kind => PosteRemoteWrites.RestartCancelKind;
    public bool OwnsPendingRestart(WritePlan original) => OwnsPendingRestartPlan(original);
    public Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken) => PrepareAsync(dn, null, null, null, null, cancellationToken);
}
public sealed class AdPosteGpUpdateExecutor(AdDirectorySource source) : AdPosteRemoteExecutor(source), IPosteGpUpdateExecutor
{
    public override string Kind => PosteRemoteWrites.GpUpdateKind;
    public Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken) => PrepareAsync(dn, null, null, null, null, cancellationToken);
}
public sealed class AdPosteServiceExecutor(AdDirectorySource source) : AdPosteRemoteExecutor(source), IPosteServiceExecutor
{
    public override string Kind => PosteRemoteWrites.ServiceKind;
    public Task<WritePlanDraft> PlanAsync(string dn, string service, string action, CancellationToken cancellationToken) => PrepareAsync(dn, null, null, service, action, cancellationToken);
}
public sealed class AdPosteRunExecutor(AdDirectorySource source) : AdPosteRemoteExecutor(source), IPosteRunExecutor
{
    public override string Kind => PosteRemoteWrites.RunKind;
    public Task<WritePlanDraft> PlanAsync(string dn, RunRequest request, CancellationToken cancellationToken) => PrepareAsync(dn, null, request, null, null, cancellationToken);
}
public sealed class AdPosteWakeExecutor(AdDirectorySource source) : AdPosteRemoteExecutor(source), IPosteWakeExecutor
{
    public override string Kind => PosteRemoteWrites.WakeKind;
    public Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken) => PrepareAsync(dn, null, null, null, null, cancellationToken);
}
