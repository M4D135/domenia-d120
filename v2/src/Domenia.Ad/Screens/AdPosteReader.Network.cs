using System.Collections.Immutable;
using System.Net.NetworkInformation;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    internal Func<PosteConfiguration, WmiWorkstationReader>? InventoryReaderOverride { get; init; }
    internal Func<string, RemoteProbeCredential, CancellationToken, Task<WindowsSessionsRead>>? SessionsOverride { get; init; }
    private readonly Lock recentGate = new();
    private readonly Dictionary<Guid, RecentPoste> recent = [];
    private long recentEpoch = -1;
    private sealed record RecentPoste(DateTimeOffset At, PosteLive? Live = null, SoftwareResult? Software = null);

    private RecentPoste? Recent(Guid guid, long epoch, RecentPoste? next = null)
    {
        lock (recentGate)
        {
            EnsureEpoch(epoch);
            if (recentEpoch != epoch) { recent.Clear(); recentEpoch = epoch; }
            var old = recent.GetValueOrDefault(guid);
            if (next is null) { return old; }
            if (old is not null)
            {
                next = next with
                {
                    At = old.At > next.At ? old.At : next.At,
                    Live = next.Live is null || old.Live?.At > next.Live.At ? old.Live : next.Live,
                    Software = next.Software is null || old.Software?.ReadAt > next.Software.ReadAt ? old.Software : next.Software,
                };
            }
            recent[guid] = next;
            while (recent.Count > 128) { recent.Remove(recent.MinBy(p => p.Value.At).Key); }
            return next;
        }
    }

    private async Task<LocalPoste> NetworkAsync(string dn, CancellationToken token, bool machine = true)
    {
        var local = await LocalAsync(dn, token).ConfigureAwait(false);
        var entry = await new AdFicheObjects(source).ReadExactAsync(dn, AdDirectoryMapper.ComputerAttributes, TimeSpan.FromSeconds(10), token).ConfigureAwait(false);
        var computer = entry is not null && entry.Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase) ? AdDirectoryMapper.Computer(entry) : null;
        if (computer is null || computer.ObjectGuid != local.Computer.ObjectGuid)
        { throw new DomeniaOperationException(PosteErrors.ComputerUnknown, "Le compte ordinateur a disparu ou changé d’identité ; aucun contact machine envoyé."); }
        if (machine && (computer.DnsHostName is not { } host || !CimQuery.IsHostName(host) || WorkstationIdentity.ExpectedName(computer) is null))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Compte machine et nom DNS absents, invalides ou incohérents ; aucun contact distant."); }
        EnsureEpoch(local.Epoch);
        // ReadExactAsync expands membership ranges; this is not a truncated object projection.
        await source.RememberObjectsAsync(new(local.Directory.Domain, source.Clock.GetUtcNow(), false, [], [], [computer], []), local.Epoch, token).ConfigureAwait(false);
        return local with { Computer = computer };
    }

    private WmiWorkstationReader InventoryReader(AdWorkstationAccess access) => InventoryReaderOverride?.Invoke(access.Settings) ?? access.InventoryReader();

    private static void ConfirmIdentity(DirectoryComputer computer, string? reported)
    {
        if (!WorkstationIdentity.Matches(computer, reported))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Identité Windows absente ou différente du compte ordinateur ; contenu non associé à ce poste."); }
    }

    private static FactState ReadState(SourceStatus status) => status switch
    {
        SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial => FactState.Observed,
        SourceStatus.Refused => FactState.Refused,
        SourceStatus.Unreachable or SourceStatus.Unavailable or SourceStatus.Error => FactState.Unavailable,
        _ => FactState.Unknown,
    };

    private async Task<InventorySnapshot> ReadAsync(LocalPoste local, WorkstationReading scope, IProgress<PosteProgress>? progress, CancellationToken token)
    {
        using var access = await AdWorkstationAccess.AcquireAsync(source, local.Computer.DnsHostName!, token).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        var value = await InventoryReader(access).ReadAsync(local.Computer.DnsHostName!, scope, progress, token, access.Credential).ConfigureAwait(false);
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        if (value.Access.Any(a => a.Status == SourceStatus.Refused || a.AuthenticationRejected))
        { access.Refused(local.Computer.DnsHostName!, "Lecture " + scope, value.Access.Any(a => a.AuthenticationRejected)); }
        if (value.ReportedName is not null) { ConfirmIdentity(local.Computer, value.ReportedName); }
        else
        {
            // A refused identity read is useful as an access report, but no payload may be attributed to this AD object.
            foreach (var row in value.Access)
            {
                value = value.WithStatus([row.Category], row.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial ? SourceStatus.Unavailable : row.Status,
                    row.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial ? "Identité Windows non confirmée ; données écartées." : row.Detail ?? "Source non lue.");
            }
        }
        return value;
    }

    public async Task<PresenceReading> PingAsync(string dn, CancellationToken cancellationToken) =>
        await PingAsync(await NetworkAsync(dn, cancellationToken).ConfigureAwait(false), cancellationToken).ConfigureAwait(false);

    private async Task<PresenceReading> PingAsync(LocalPoste local, CancellationToken token)
    {
        var at = source.Clock.GetUtcNow();
        var last = local.Observation?.Presence.LastOnlineAt;
        PresenceReading reading;
        MeasureState state;
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(1500), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, timeout.Token);
        using var ping = new Ping();
        try
        {
            var response = await ping.SendPingAsync(local.Computer.DnsHostName!, TimeSpan.FromSeconds(1), null, null, stop.Token).ConfigureAwait(false);
            var answered = response.Status == IPStatus.Success;
            reading = new(answered, answered ? (int)Math.Clamp(response.RoundtripTime, 0, int.MaxValue) : null,
                answered ? response.Address.ToString() : null, at, answered ? at : last, false, "Un écho ICMP (1 s) ; le silence ne prouve pas l’arrêt du poste.");
            state = MeasureState.Known;
        }
        catch (PingException) { reading = new(null, null, null, at, last, false, "Échec du test ICMP ; présence inconnue."); state = MeasureState.Error; }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { reading = new(null, null, null, at, last, false, "Délai du test ICMP atteint ; présence inconnue."); state = MeasureState.Incomplete; }
        EnsureEpoch(local.Epoch);
        await source.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(at, [new(local.Computer.ObjectGuid,
            new(state, reading.Answered, at, reading.LastOnlineAt), InventoryMeasure.Unread)]) }, local.Epoch, CancellationToken.None).ConfigureAwait(false);
        return reading;
    }

    public async Task<InventoryResult> InventoryAsync(string dn, bool deep, PosteHealthPolicy policy, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(policy);
        var local = await NetworkAsync(dn, cancellationToken).ConfigureAwait(false);
        var value = await ReadAsync(local, deep ? WorkstationReading.Full : WorkstationReading.Quick, progress, cancellationToken).ConfigureAwait(false);
        var confirmed = WorkstationIdentity.Matches(local.Computer, value.ReportedName);
        if (confirmed) { await source.SaveFleetAsync(AdSearchReader.MapInventory(local.Computer.ObjectGuid, value), local.Epoch, CancellationToken.None).ConfigureAwait(false); }
        var now = source.Clock.GetUtcNow();
        var board = PosteBoardBuilder.Build(Computer(local, Names(local.Directory)), value, policy, now, source.Zone);
        return InventoryRows.Build(value, board, confirmed ? "Relevé réel de cette session" : "Identité non confirmée ; aucune donnée enregistrée", now, source.Zone,
            value.Interrupted ? "Lecture arrêtée ; seules les sources déjà lues et l’identité confirmée sont conservées." : null);
    }

    public async Task<PosteLive> LiveAsync(string dn, CancellationToken cancellationToken)
    {
        var local = await NetworkAsync(dn, cancellationToken).ConfigureAwait(false);
        var presence = await PingAsync(local, cancellationToken).ConfigureAwait(false);
        // ICMP can be filtered independently of CIM; silence is not a reason to fabricate an offline state.
        var value = await ReadAsync(local, WorkstationReading.Live, null, cancellationToken).ConfigureAwait(false);
        var now = value.CollectedAt;
        var boot = value.Os?.LastBoot is { } at && at <= now ? at : (DateTimeOffset?)null;
        var system = value.StatusOf(InventoryCategories.System);
        var user = value.System?.UserName is { Length: > 0 } login ? new UserRef(login, login, null, null) : null;
        var sessionStatus = value.StatusOf(InventoryCategories.Sessions);
        var sessions = PosteSessions.View(local.Computer.Name, sessionStatus, value.Sessions, now, "Compte machine sélectionné", source.Zone);
        var count = sessionStatus is SourceStatus.Ok or SourceStatus.Empty && sessions.UnreadSessions == 0 ? sessions.UserSessions : (int?)null;
        var consoleKnown = value.System is not null && system is SourceStatus.Ok or SourceStatus.Empty;
        var consoleText = user?.Name ?? (consoleKnown ? "Aucun utilisateur à la console" : "Compte de console non lu");
        var facts = ImmutableArray.Create(
            PosteText.Fact("Présence", presence.Answered == true ? "Répond au ping" : presence.Answered == false ? "Ne répond pas au ping" : "Inconnue", presence.Answered is null ? FactState.Unknown : FactState.Observed, presence.Source, at: presence.CheckedAt),
            PosteText.Fact("Durée de fonctionnement", boot is null ? "Non lue" : PosteText.Duration(now - boot.Value), boot is null ? FactState.Unknown : FactState.Observed, "Win32_OperatingSystem", "Heure déclarée par Windows.", at: now),
            PosteText.Fact("Utilisateur connecté", consoleText, user is not null || consoleKnown ? FactState.Observed : ReadState(system), "Win32_ComputerSystem", "Nom de console ; aucun GUID utilisateur déduit du seul nom.", at: now),
            PosteText.Fact("Sessions", sessions.StatusText, sessions.ReadState, "Sessions CIM", sessions.Partial ? "Lecture partielle ; total inconnu." : null, at: now));
        var live = new PosteLive(presence, boot, boot is null ? null : PosteText.Duration(now - boot.Value), user, consoleText, count, sessions.StatusText, now, facts);
        if (WorkstationIdentity.Matches(local.Computer, value.ReportedName))
        {
            var mapped = AdSearchReader.MapInventory(local.Computer.ObjectGuid, value);
            var patch = FleetCachePatch.Empty with { Machines = mapped.Machines };
            await source.SaveFleetAsync(patch, local.Epoch, CancellationToken.None).ConfigureAwait(false);
        }
        Recent(local.Computer.ObjectGuid, local.Epoch, new(now, Live: live));
        return live;
    }

    public async Task<SoftwareResult> SoftwareAsync(string dn, SoftwareRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var local = await NetworkAsync(dn, cancellationToken).ConfigureAwait(false);
        using var access = await AdWorkstationAccess.AcquireAsync(source, local.Computer.DnsHostName!, cancellationToken).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        var read = await InventoryReader(access).ReadSoftwareAsync(local.Computer.DnsHostName!, request, cancellationToken, access.Credential).ConfigureAwait(false);
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        if (read.AuthenticationRejected || read.Access.Any(a => a.Status == SourceStatus.Refused)) { access.Refused(local.Computer.DnsHostName!, "Logiciels", read.AuthenticationRejected); }
        if (read.ReportedName is not null) { ConfirmIdentity(local.Computer, read.ReportedName); }
        else
        {
            if (!read.Entries.IsEmpty) { ConfirmIdentity(local.Computer, null); }
            read = read with { Access = [.. read.Access.Select(a => a.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial
                ? a with { Status = SourceStatus.Unavailable, StatusLabel = PosteLabels.SourceStatusLabel(SourceStatus.Unavailable), Detail = "Identité Windows non confirmée ; aucune absence de logiciel établie." } : a)] };
        }
        var rows = PosteSoftware.Rows(read.Entries);
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(read.CollectedAt, source.Zone).DateTime);
        var result = new SoftwareResult(local.Computer.Name, read.CollectedAt, "Relevé réel de cette session", "Portées et refus détaillés ci-dessous ; les noms identiques ne sont pas fusionnés.",
            read.ReportedName is not null && read.Complete, rows.Length, rows, read.Access, PosteSoftware.AccessSummary(read.Access), PosteSoftware.NotCovered(read.Access, request), PosteSoftware.Columns(rows), PosteSoftware.Board(rows, today), []);
        Recent(local.Computer.ObjectGuid, local.Epoch, new(read.CollectedAt, Software: result));
        return result;
    }

    public async Task<ServicesResult> ServicesAsync(string dn, CancellationToken cancellationToken)
    {
        var local = await NetworkAsync(dn, cancellationToken).ConfigureAwait(false);
        var read = await ReadAsync(local, WorkstationReading.Services, null, cancellationToken).ConfigureAwait(false);
        var status = read.StatusOf(InventoryCategories.Services);
        var rows = PosteServices.Rows(read.Services);
        var auto = rows.Count(r => r.AutoStopped); var expected = rows.Count(r => r.StopExpected);
        var partial = status != SourceStatus.Ok && status != SourceStatus.Empty;
        var detail = read.Access.FirstOrDefault(a => a.Category == InventoryCategories.Services)?.Detail;
        return new(local.Computer.Name, read.CollectedAt, rows.Length, auto, expected, rows.Length >= PosteServices.Cap, 0,
            partial ? PosteLabels.SourceStatusLabel(status) + " · " + FrenchText.Count(rows.Length, "service visible", "services visibles") + " ; bilan incomplet."
                : PosteServices.Summary(rows.Length, auto, expected, local.Computer.Name, read.CollectedAt, source.Zone, false),
            rows, partial ? [] : PosteServices.CompareProfile(rows),
            [PosteText.Fact("Lecture", PosteLabels.SourceStatusLabel(status), ReadState(status), "Win32_Service / " + PosteLabels.TransportLabel(read.Transport), detail, at: read.CollectedAt)]);
    }

    public async Task<ProcessesResult> ProcessesAsync(string dn, CancellationToken cancellationToken)
    {
        var local = await NetworkAsync(dn, cancellationToken).ConfigureAwait(false);
        var read = await ReadAsync(local, WorkstationReading.Processes, null, cancellationToken).ConfigureAwait(false);
        var status = read.StatusOf(InventoryCategories.Processes);
        var detail = read.Access.FirstOrDefault(a => a.Category == InventoryCategories.Processes)?.Detail;
        var fact = PosteText.Fact("Lecture", PosteLabels.SourceStatusLabel(status), ReadState(status), "Win32_Process / " + PosteLabels.TransportLabel(read.Transport), detail, at: read.CollectedAt);
        if (read.ProcessSample is { } sample)
        {
            return sample with { Computer = local.Computer.Name, TotalCpu = status == SourceStatus.Partial ? null : sample.TotalCpu,
                Summary = sample.Summary + (status == SourceStatus.Partial ? " Lecture partielle ; charge totale inconnue." : ""),
                Facts = [.. sample.Facts.Select(f => status == SourceStatus.Partial && f.Label == "Charge mesurée"
                    ? f with { Value = "Total inconnu ; échantillon partiel", State = FactState.Unknown, Tone = Tone.Off } : f), fact] };
        }
        return new(local.Computer.Name, read.CollectedAt, 0, read.System?.LogicalProcessors ?? 0, null, 0, [],
            "Aucune mesure exploitable : " + PosteLabels.SourceStatusLabel(status) + ".", [fact]);
    }

    public async Task<EventsResult> EventsAsync(string dn, string preset, int hours, int maxEvents, CancellationToken cancellationToken)
    {
        var definition = PosteEvents.Preset(preset) ?? throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Préréglage d’événements inconnu.");
        var query = PosteEvents.Query(definition, hours, maxEvents, source.Clock.GetUtcNow());
        var local = await NetworkAsync(dn, cancellationToken).ConfigureAwait(false);
        using var access = await AdWorkstationAccess.AcquireAsync(source, local.Computer.DnsHostName!, cancellationToken).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        var read = await InventoryReader(access).ReadEventsAsync(local.Computer.DnsHostName!, query, cancellationToken, access.Credential).ConfigureAwait(false);
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        if (read.Status == SourceStatus.Refused || read.AuthenticationRejected) { access.Refused(local.Computer.DnsHostName!, "Événements", read.AuthenticationRejected); }
        if (read.ReportedName is not null) { ConfirmIdentity(local.Computer, read.ReportedName); }
        var result = PosteEvents.Interpret(WorkstationIdentity.ExpectedName(local.Computer)!, query, read.Status, read.Events,
            read.Status == SourceStatus.Partial, access.Credential.Account, source.Zone);
        return result with { Computer = local.Computer.Name, Facts = result.Facts.Add(PosteText.Fact("Source", PosteLabels.SourceStatusLabel(read.Status),
            ReadState(read.Status), "Journaux Windows", read.Detail, at: read.At)) };
    }

    public async Task<SessionsResult> SessionsAsync(string dn, CancellationToken cancellationToken)
    {
        var local = await NetworkAsync(dn, cancellationToken).ConfigureAwait(false);
        using var access = await AdWorkstationAccess.AcquireAsync(source, local.Computer.DnsHostName!, cancellationToken).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        var credential = access.Credential;
        var name = CredentialRules.Parse(credential.Account);
        var user = credential.Session ? null : name.Form == AccountNameForm.Upn ? credential.Account : name.Name;
        var domain = credential.Session || name.Form == AccountNameForm.Upn ? null : name.Authority;
        var started = source.Clock.GetTimestamp();
        var read = SessionsOverride is { } injected ? await injected(local.Computer.DnsHostName!, credential, cancellationToken).ConfigureAwait(false)
            : await new WindowsSessionsReader(source.Clock).ReadAsync(local.Computer.DnsHostName!, user, domain, credential.Password, cancellationToken, TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        if (SessionsOverride is null && WmiLogonSessionsReader.NeedsFallback(read))
        {
            access.EnsureCurrent();
            var remaining = TimeSpan.FromSeconds(5) - source.Clock.GetElapsedTime(started);
            if (remaining > TimeSpan.Zero)
            {
                try
                {
                    var fallback = await new WmiLogonSessionsReader(source.Clock).ReadAsync(local.Computer.DnsHostName!, credential, remaining, cancellationToken, access.Settings).ConfigureAwait(false);
                    read = fallback with { Detail = "WTS : " + read.Detail + " " + fallback.Detail };
                }
                catch (DomeniaOperationException ex) when (ex.Code == "machine.busy") { read = read with { Detail = read.Detail + " Lecteurs CIM occupés ; repli non envoyé." }; }
            }
        }
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        if (read.Status == SourceStatus.Refused || read.AuthenticationRejected) { access.Refused(local.Computer.DnsHostName!, "Sessions", read.AuthenticationRejected); }
        var result = PosteSessions.View(local.Computer.Name, read.Status, read.Sessions, read.At, credential.Account, source.Zone);
        return result with { StatusText = result.StatusText + (string.IsNullOrEmpty(read.Detail) ? "" : " " + read.Detail) };
    }
}
