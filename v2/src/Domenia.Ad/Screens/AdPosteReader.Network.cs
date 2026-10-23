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
    private sealed record RecentPoste(DateTimeOffset At, PosteLive? Live = null, SoftwareResult? Software = null, DetectedUser? Detected = null);

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
                    Detected = next.Detected is null || old.Detected?.ReadAt > next.Detected.ReadAt ? old.Detected : next.Detected,
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
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(10), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token, elapsed.Token);
        using var directory = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, dn, budget.Token).ConfigureAwait(false);
        return await NetworkIdentityAsync(local, directory, budget.Token, machine).ConfigureAwait(false);
    }

    private async Task<LocalPoste> NetworkIdentityAsync(LocalPoste local, AdReadAccess directory, CancellationToken token, bool machine = true)
    {
        var dn = local.Computer.DistinguishedName;
        IReadOnlyList<AdEntry> rows;
        try
        {
            rows = await directory.SearchAsync(new(dn, "(objectClass=computer)", AdSearchScope.Base, [.. AdDirectoryMapper.ComputerAttributes, "objectClass"])
            { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(10), ExpandRanges = true, MaxRangeValues = 50_000 }, token).ConfigureAwait(false);
        }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.NoSuchObject) { rows = []; }
        var entry = rows.Count == 1 && DistinguishedName.AreEqual(rows[0].DistinguishedName, dn) ? rows[0] : null;
        var computer = entry is not null && entry.Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase) ? AdDirectoryMapper.Computer(entry) : null;
        if (computer is null || computer.ObjectGuid != local.Computer.ObjectGuid || computer.Sid != local.Computer.Sid || computer.WhenCreated != local.Computer.WhenCreated
            || computer.WhenCreated == DateTimeOffset.MinValue || computer.WhenCreated > source.Clock.GetUtcNow())
        { throw new DomeniaOperationException(PosteErrors.ComputerUnknown, "Le compte ordinateur a disparu ou changé d’identité ; lecture interrompue, aucun contenu attribué à ce poste."); }
        if (machine && (computer.DnsHostName is not { } host || !CimQuery.IsHostName(host) || WorkstationIdentity.ExpectedName(computer) is null))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Compte machine et nom DNS absents, invalides ou incohérents ; aucun contact distant."); }
        directory.EnsureCurrent(); EnsureEpoch(local.Epoch); token.ThrowIfCancellationRequested();
        // The selected LDAP lease expands memberships before this projection can replace the local computer object.
        await source.RememberObjectsAsync(new(local.Directory.Domain, source.Clock.GetUtcNow(), false, [], [], [computer], []), local.Epoch, token).ConfigureAwait(false);
        directory.EnsureCurrent(); EnsureEpoch(local.Epoch);
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
        var local = await LocalAsync(dn, cancellationToken).ConfigureAwait(false);
        TaskFallback? fallback = null;
        var qualified = await new AdRelationsReader(source) { InventoryReaderOverride = InventoryReaderOverride }
            .InventoryAsync(local.Computer, deep ? WorkstationReading.Full : WorkstationReading.Quick, progress, cancellationToken, afterRead: async (direct, machine, stop) =>
            {
                if (!NeedsTaskFallback(direct) || direct.ReportedName is not null && !WorkstationIdentity.Matches(local.Computer, direct.ReportedName) || stop.IsCancellationRequested) { return direct; }
                fallback = await ReadTaskFallbackAsync(local, machine, deep ? RemoteTaskReadKind.InventoryFull : RemoteTaskReadKind.InventoryQuick, null,
                    direct.Access.Any(a => a.AuthenticationRejected), stop).ConfigureAwait(false);
                return fallback.Result?.Inventory is { } read ? MergeTaskInventory(direct, read) : direct;
            }).ConfigureAwait(false);
        var value = qualified.Value;
        var confirmed = WorkstationIdentity.Matches(local.Computer, value.ReportedName);
        if (confirmed) { await source.SaveFleetAsync(AdSearchReader.MapInventory(local.Computer.ObjectGuid, value), local.Epoch, CancellationToken.None).ConfigureAwait(false); }
        var now = source.Clock.GetUtcNow();
        var board = PosteBoardBuilder.Build(Computer(local, Names(local.Directory)), value, policy, now, source.Zone);
        return InventoryRows.Build(value, board, confirmed ? "Relevé réel de cette session" : "Identité non confirmée ; aucune donnée enregistrée", now, source.Zone,
            qualified.Notice + (fallback is null ? "" : " " + fallback.Notice) + (value.Interrupted ? " Lecture arrêtée ; seules les sources déjà lues et l’identité confirmée sont conservées." : ""), fallback?.Action) with
        { NoticeTone = qualified.Denied || !confirmed || fallback?.Result is { CleanupConfirmed: false } ? Tone.Warn : Tone.Info };
    }

    public async Task<PosteLive> LiveAsync(string dn, CancellationToken cancellationToken)
    {
        var local = await LocalAsync(dn, cancellationToken).ConfigureAwait(false);
        PresenceReading? measured = null;
        // The fresh DNS target and the whole inventory share one LDAP lease, including a one-shot identity.
        var qualified = await new AdRelationsReader(source) { InventoryReaderOverride = InventoryReaderOverride }
            .InventoryAsync(local.Computer, WorkstationReading.Live, null, cancellationToken, beforeRead: async (host, stop) =>
            {
                measured = await PingAsync(local with { Computer = local.Computer with { DnsHostName = host } }, stop).ConfigureAwait(false);
            }).ConfigureAwait(false);
        var presence = measured ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Présence non mesurée dans ce geste.");
        // ICMP can be filtered independently of CIM; its silence does not fabricate an offline state.
        var value = qualified.Value;
        var now = value.CollectedAt;
        var boot = value.Os?.LastBoot is { } at && at <= now ? at : (DateTimeOffset?)null;
        var system = value.StatusOf(InventoryCategories.System);
        var user = value.Console?.Account is { Length: > 0 } login ? new UserRef(login, login, null, null) : null;
        var sessionStatus = value.StatusOf(InventoryCategories.Sessions);
        var sessions = PosteSessions.View(local.Computer.Name, sessionStatus, value.Sessions, now, "Compte machine sélectionné", source.Zone);
        var count = sessionStatus is SourceStatus.Ok or SourceStatus.Empty && sessions.UnreadSessions == 0 ? sessions.UserSessions : (int?)null;
        var consoleKnown = value.Console is not null;
        var consoleText = user?.Name ?? (consoleKnown ? "Aucun utilisateur à la console" : "Compte de console non lu");
        var facts = ImmutableArray.Create(
            PosteText.Fact("Présence", presence.Answered == true ? "Répond au ping" : presence.Answered == false ? "Ne répond pas au ping" : "Inconnue", presence.Answered is null ? FactState.Unknown : FactState.Observed, presence.Source, at: presence.CheckedAt),
            PosteText.Fact("Durée de fonctionnement", boot is null ? "Non lue" : PosteText.Duration(now - boot.Value), boot is null ? FactState.Unknown : FactState.Observed, "Win32_OperatingSystem", "Heure déclarée par Windows.", at: now),
            PosteText.Fact("Utilisateur connecté", consoleText, user is not null || consoleKnown ? FactState.Observed : ReadState(system), "Win32_ComputerSystem", "Nom de console ; aucun GUID utilisateur déduit du seul nom.", at: value.Console?.At),
            PosteText.Fact("Sessions", sessions.StatusText, sessions.ReadState, "Sessions CIM", sessions.Partial ? "Lecture partielle ; total inconnu." : null, at: now),
            PosteText.Fact("Relations", value.Console is null ? "Console non qualifiée" : "Console observée", value.Console is null ? FactState.Unknown : FactState.Observed,
                "Console et annuaire", qualified.Notice, at: value.Console?.At));
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
        TaskFallback? fallback = null;
        if ((!read.Complete || read.ReportedName is null) && !read.AuthenticationRejected
            && (read.ReportedName is null || WorkstationIdentity.Matches(local.Computer, read.ReportedName)) && !cancellationToken.IsCancellationRequested)
        {
            fallback = await ReadTaskFallbackAsync(local, access, RemoteTaskReadKind.Software, request, false, cancellationToken).ConfigureAwait(false);
            if (fallback.Result?.Software is { } extra)
            {
                var replace = extra.Access.Where(a => a.Status is SourceStatus.Ok or SourceStatus.Empty
                    || a.Status == SourceStatus.Partial && !read.Access.Any(old => old.Scope == a.Scope && old.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial))
                    .Where(a => !read.Access.Any(old => old.Scope == a.Scope && old.Status is SourceStatus.Ok or SourceStatus.Empty)).Select(a => a.Scope).ToHashSet(StringComparer.Ordinal);
                read = read with { ReportedName = extra.ReportedName, CollectedAt = extra.CollectedAt,
                    Entries = [.. read.Entries.Where(e => !replace.Contains(e.Scope)), .. extra.Entries.Where(e => replace.Contains(e.Scope))],
                    Access = [.. read.Access.Where(a => !replace.Contains(a.Scope)), .. extra.Access.Where(a => replace.Contains(a.Scope))] };
            }
        }
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
            read.ReportedName is not null && read.Complete, rows.Length, rows, read.Access, PosteSoftware.AccessSummary(read.Access), PosteSoftware.NotCovered(read.Access, request), PosteSoftware.Columns(rows), PosteSoftware.Board(rows, today), [])
            { Notice = fallback?.Notice, NoticeAction = fallback?.Action };
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
        var local = await LocalAsync(dn, cancellationToken).ConfigureAwait(false);
        var previous = await StoredSessionsAsync(local, cancellationToken).ConfigureAwait(false);
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(25), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        // A one-shot LDAP identity belongs to this entire gesture, including the final parent check.
        using var directory = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, dn, budget.Token).ConfigureAwait(false);
        local = await NetworkIdentityAsync(local, directory, budget.Token).ConfigureAwait(false);
        using var access = await AdWorkstationAccess.AcquireAsync(source, local.Computer.DnsHostName!, budget.Token).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        var credential = access.Credential;
        var name = CredentialRules.Parse(credential.Account);
        var user = credential.Session ? null : name.Form == AccountNameForm.Upn ? credential.Account : name.Name;
        var domain = credential.Session || name.Form == AccountNameForm.Upn ? null : name.Authority;
        var started = source.Clock.GetTimestamp();
        var read = SessionsOverride is { } injected ? await injected(local.Computer.DnsHostName!, credential, budget.Token).ConfigureAwait(false)
            : await new WindowsSessionsReader(source.Clock).ReadAsync(local.Computer.DnsHostName!, user, domain, credential.Password, budget.Token, TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        if (SessionsOverride is null && WmiLogonSessionsReader.NeedsFallback(read))
        {
            access.EnsureCurrent();
            var remaining = TimeSpan.FromSeconds(5) - source.Clock.GetElapsedTime(started);
            if (remaining > TimeSpan.Zero)
            {
                try
                {
                    var fallback = await new WmiLogonSessionsReader(source.Clock).ReadAsync(local.Computer.DnsHostName!, credential, remaining, budget.Token, access.Settings).ConfigureAwait(false);
                    read = fallback with
                    {
                        // CIM logons are useful history, but never establish a complete WTS desktop list (including zero).
                        Status = fallback.Status is SourceStatus.Ok or SourceStatus.Empty ? SourceStatus.Partial : fallback.Status,
                        Detail = "WTS : " + read.Detail + " " + fallback.Detail,
                    };
                }
                catch (DomeniaOperationException ex) when (ex.Code == "machine.busy") { read = read with { Detail = read.Detail + " Lecteurs CIM occupés ; repli non envoyé." }; }
            }
        }
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        if (read.Status == SourceStatus.Refused || read.AuthenticationRejected) { access.Refused(local.Computer.DnsHostName!, "Sessions", read.AuthenticationRejected); }
        if (!read.Sessions.IsEmpty || read.Status is SourceStatus.Ok or SourceStatus.Empty)
        {
            var final = await NetworkIdentityAsync(local, directory, budget.Token).ConfigureAwait(false);
            if (!string.Equals(final.Computer.DnsHostName, local.Computer.DnsHostName, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(final.Computer.SamAccountName, local.Computer.SamAccountName, StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(PosteErrors.ComputerUnknown, "Cible DNS ou compte machine modifié pendant la lecture ; sessions non attribuées."); }
        }
        directory.EnsureCurrent(); access.EnsureCurrent(); EnsureEpoch(local.Epoch); budget.Token.ThrowIfCancellationRequested();
        var attempt = new WorkstationSessionRead(read.At, read.Status, read.Sessions, read.Unread, credential.Account, PosteText.Flat(read.Detail ?? "", 2048))
        { AuthenticationRejected = read.AuthenticationRejected };
        var memory = new WorkstationSessionMemory(WorkstationIdentity.ExpectedName(local.Computer)!, attempt, attempt.Complete ? attempt : null);
        PosteSessionCache.Validate(memory, source.Clock.GetUtcNow());
        if (attempt.At < local.Computer.WhenCreated) { throw new InvalidDataException("Lecture de sessions antérieure au compte ordinateur."); }
        memory = PosteSessionCache.Merge(previous.Memory, memory);
        var notice = source.LocalStore is IAccueilCache ? "Lecture enregistrée dans la base locale." : "Lecture conservée dans cette session ; base locale indisponible.";
        try
        {
            var saved = await source.SaveFleetAsync(FleetCachePatch.Empty with
            { WorkstationSessions = ImmutableDictionary<Guid, WorkstationSessionMemory>.Empty.Add(local.Computer.ObjectGuid, memory) }, local.Epoch, CancellationToken.None).ConfigureAwait(false);
            memory = saved.WorkstationSessions[local.Computer.ObjectGuid];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            notice = "Lecture reçue, mais enregistrement local non confirmé ; la base antérieure reste disponible.";
        }
        EnsureEpoch(local.Epoch);
        return PosteSessions.Stored(memory, source.Zone, cached: memory.Latest != attempt) with { CacheNotice = notice };
    }
}
