using System.Collections.Immutable;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdSearchReader
{
    internal Func<string, CancellationToken, Task<InventorySnapshot>>? InventoryOverride { get; init; }
    internal Func<string, CancellationToken, Task<PresenceMeasure>>? EchoOverride { get; init; }

    public async Task<string?> ReverseDnsAsync(string ipv4, CancellationToken cancellationToken)
    {
        if (SearchText.ParseAddress(ipv4)?.Kind != "ipv4") { throw Invalid("Une adresse IPv4 complète est requise."); }
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try
        {
            var entry = await Dns.GetHostEntryAsync(ipv4, AddressFamily.InterNetwork, budget.Token).ConfigureAwait(false);
            return IPAddress.TryParse(entry.HostName, out _) ? null : entry.HostName;
        }
        catch (SocketException ex) when (ex.SocketErrorCode is SocketError.HostNotFound or SocketError.NoData) { return null; }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "DNS inverse : délai de 15 secondes dépassé."); }
    }

    private async Task<(DirectoryState State, DirectoryComputer Computer)> ComputerAsync(Guid id, CancellationToken token)
    {
        var state = await source.ReadLocalAsync(token).ConfigureAwait(false);
        var computer = state.Directory.Computers.FirstOrDefault(c => c.ObjectGuid == id)
            ?? throw new DomeniaOperationException(SearchErrors.NotWorkstation, SearchErrors.NotWorkstationMessage);
        if (string.IsNullOrWhiteSpace(computer.DnsHostName) || !CimQuery.IsHostName(computer.DnsHostName))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Nom DNS du poste absent ou invalide : aucun test envoyé."); }
        return (state, computer);
    }

    private async Task<PresenceMeasure> EchoAsync(string host, DateTimeOffset? lastOnline, CancellationToken token)
    {
        if (EchoOverride is { } injected) { return await injected(host, token).ConfigureAwait(false); }
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(2), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        using var ping = new Ping();
        var at = source.Clock.GetUtcNow();
        try
        {
            var answer = await ping.SendPingAsync(host, TimeSpan.FromSeconds(1), null, null, budget.Token).ConfigureAwait(false);
            var online = answer.Status == IPStatus.Success;
            return new(MeasureState.Known, online, at, online ? at : lastOnline);
        }
        catch (PingException) { return new(MeasureState.Error, null, at, lastOnline); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { return new(MeasureState.Incomplete, null, at, lastOnline); }
    }

    public async Task<SurveyOutcome> ProbeAsync(Guid id, SurveyMode mode, int run, TimeSpan inventoryReuse, CancellationToken cancellationToken)
    {
        _ = run;
        if (!Enum.IsDefined(mode)) { throw Invalid("Mode de relevé inconnu."); }
        var (state, computer) = await ComputerAsync(id, cancellationToken).ConfigureAwait(false);
        var generation = source.Epoch;
        var old = state.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == id);
        var presence = await EchoAsync(computer.DnsHostName!, old?.Presence.LastOnlineAt, cancellationToken).ConfigureAwait(false);
        var patch = FleetCachePatch.Empty with { Observations = new(source.Clock.GetUtcNow(), [new(id, presence, InventoryMeasure.Unread)]) };
        // The completed echo is durable even if the operator stops during the subsequent CIM read.
        await source.SaveFleetAsync(patch, generation, CancellationToken.None).ConfigureAwait(false);
        SearchConsole? console = null;
        var reused = false;
        var denied = false;
        string? detail = null;
        if (presence is { HasReading: true, Answered: true } && mode != SurveyMode.Ping)
        {
            var inventory = old?.Inventory;
            reused = mode == SurveyMode.Analyse && inventoryReuse > TimeSpan.Zero && inventory is { HasReading: true, CheckedAt: { } at }
                && source.Clock.GetUtcNow() >= at && source.Clock.GetUtcNow() - at <= inventoryReuse;
            if (mode is SurveyMode.Console or SurveyMode.Unaddressed || reused)
            {
                using var access = await AdWorkstationAccess.AcquireAsync(source, computer.DnsHostName!, cancellationToken).ConfigureAwait(false);
                var seen = await access.InventoryReader().ReadConsoleAccountAsync(computer.DnsHostName!, cancellationToken, access.Credential).ConfigureAwait(false);
                access.EnsureCurrent();
                if (seen?.Status == SourceStatus.Refused) { access.Refused(computer.Name, "Lecture de la console", seen.AuthenticationRejected); }
                cancellationToken.ThrowIfCancellationRequested();
                if (seen is not null)
                {
                    denied = seen.Status == SourceStatus.Refused;
                    if (seen.Status is SourceStatus.Ok or SourceStatus.Empty && string.Equals(seen.ReportedName, computer.Name, StringComparison.OrdinalIgnoreCase))
                    {
                        var facts = new MachineFacts(seen.ConsoleUser, source.Clock.GetUtcNow(), null, null, MeasureState.Known, source.Clock.GetUtcNow(), null);
                        await source.SaveFleetAsync(FleetCachePatch.Empty with { Machines = ImmutableDictionary<Guid, MachineFacts>.Empty.Add(id, facts) }, generation, CancellationToken.None).ConfigureAwait(false);
                    }
                    else { detail = denied ? "Compte distant refusé : utilisateur de la console non lu." : "Lecture de la console incomplète ou indisponible."; }
                }
            }
            else
            {
                using var access = InventoryOverride is null ? await AdWorkstationAccess.AcquireAsync(source, computer.DnsHostName!, cancellationToken).ConfigureAwait(false) : null;
                var reading = InventoryOverride is { } injected ? await injected(computer.DnsHostName!, cancellationToken).ConfigureAwait(false)
                    : await access!.InventoryReader().ReadAsync(computer.DnsHostName!, mode == SurveyMode.Complete ? WorkstationReading.SurveyComplete : WorkstationReading.Survey, null, cancellationToken, access!.Credential).ConfigureAwait(false);
                access?.EnsureCurrent();
                if (reading.Access.Any(a => a.Status == SourceStatus.Refused || a.AuthenticationRejected)) { access?.Refused(computer.Name, "Relevé du poste", reading.Access.Any(a => a.AuthenticationRejected)); }
                if (!string.Equals(reading.ReportedName, computer.Name, StringComparison.OrdinalIgnoreCase))
                { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Identité CIM absente ou différente du compte ordinateur : inventaire non associé à cet objet AD."); }
                var mapped = MapInventory(id, reading);
                await source.SaveFleetAsync(mapped, generation, CancellationToken.None).ConfigureAwait(false);
                denied = reading.Access.Any(a => a.Status == SourceStatus.Refused);
                if (reading.Interrupted || reading.Access.Any(a => a.Status is SourceStatus.Partial or SourceStatus.Error or SourceStatus.Unreachable or SourceStatus.Refused))
                { detail = "Relevé partiel : les sources non lues restent inconnues ; les mesures terminées sont conservées."; }
                cancellationToken.ThrowIfCancellationRequested();
            }
            var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
            console = new Enrichment(local.Directory, source.FleetDetails).Console(id);
            if (denied) { console = new("denied", "Compte distant refusé par le poste", null, null, null, source.Clock.GetUtcNow()); }
        }
        var shown = SearchTexts.Presence(presence, source.Clock.GetUtcNow());
        return new(id.ToString("D"), computer.Name, SearchSurvey.OutcomeKind(shown.State), shown, console, detail, reused, denied);
    }

    internal static FleetCachePatch MapInventory(Guid id, InventorySnapshot reading)
    {
        var at = reading.CollectedAt;
        var system = reading.StatusOf(InventoryCategories.System);
        var status = system == SourceStatus.Refused ? MeasureState.Refused
            : system is SourceStatus.Ok or SourceStatus.Empty && reading.Os is not null && reading.System is not null ? MeasureState.Known : MeasureState.Incomplete;
        var disk = reading.Volumes.FirstOrDefault(d => string.Equals(d.Id, reading.Os?.SystemDrive, StringComparison.OrdinalIgnoreCase));
        var measure = new InventoryMeasure(status, at, disk?.SizeBytes, disk?.FreeBytes, reading.Os?.LastBoot,
            reading.System?.Model, reading.System?.TotalPhysicalMemory, reading.Os?.Caption, reading.Os?.Build);
        var facts = new MachineFacts(reading.System?.UserName, system is SourceStatus.Ok or SourceStatus.Empty && reading.System is not null ? at : null,
            reading.Bios?.Version, reading.Bios is null ? null : at, status, at, status == MeasureState.Known ? null : "Inventaire incomplet ou refusé.");
        var addresses = reading.Network.SelectMany(n => n.Ipv4.Select(ip => new SearchAddressReading(ip, SearchText.ParseAddress(n.Mac)?.Value, at, "Adresse observée lors du relevé CIM ; elle peut avoir changé.")))
            .Where(a => SearchText.ParseAddress(a.Ip)?.Kind == "ipv4").Distinct().Take(256).ToImmutableArray();
        return FleetCachePatch.Empty with
        {
            Observations = new(at, [new(id, PresenceMeasure.Unread, measure)]),
            Machines = ImmutableDictionary<Guid, MachineFacts>.Empty.Add(id, facts),
            Inventories = ImmutableDictionary<Guid, InventorySnapshot>.Empty.Add(id, reading),
            Addresses = addresses.IsEmpty ? ImmutableDictionary<Guid, ImmutableArray<SearchAddressReading>>.Empty
                : ImmutableDictionary<Guid, ImmutableArray<SearchAddressReading>>.Empty.Add(id, addresses),
        };
    }

    public async Task<NetworkDiagnosticLine> DiagnoseAsync(Guid id, CancellationToken cancellationToken)
    {
        var (_, computer) = await ComputerAsync(id, cancellationToken).ConfigureAwait(false);
        var epoch = source.Epoch;
        IPAddress? address;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15), source.Clock);
        using var dnsBudget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try { address = (await Dns.GetHostAddressesAsync(computer.DnsHostName!, AddressFamily.InterNetwork, dnsBudget.Token).ConfigureAwait(false)).FirstOrDefault(); }
        catch (SocketException) { address = null; }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { address = null; }
        if (address is null)
        {
            var error = SearchTexts.Presence(new(MeasureState.Error, null, source.Clock.GetUtcNow(), null), source.Clock.GetUtcNow());
            return new(id.ToString("D"), computer.Name, null, error,
                [.. SearchSurvey.DiagnosticPorts.Select(p => new NetworkPort(p.Port, p.Service, "untested", "Non testé", Tone.Off))], "Nom non résolu : aucun test envoyé.", Tone.Alert);
        }
        var presence = await EchoAsync(address.ToString(), null, cancellationToken).ConfigureAwait(false);
        var ports = await Task.WhenAll(SearchSurvey.DiagnosticPorts.Select(async p =>
        {
            using var client = new TcpClient(address.AddressFamily);
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(2), source.Clock);
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, limit.Token);
            try
            {
                await client.ConnectAsync(address, p.Port, budget.Token).ConfigureAwait(false);
                return new NetworkPort(p.Port, p.Service, "open", "Ouvert", Tone.Ok);
            }
            catch (SocketException ex)
            {
                return ex.SocketErrorCode == SocketError.ConnectionRefused ? new NetworkPort(p.Port, p.Service, "closed", "Fermé", Tone.Off)
                    : new NetworkPort(p.Port, p.Service, "unreachable", "Injoignable", Tone.Warn);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            { return new NetworkPort(p.Port, p.Service, "filtered", "Délai dépassé", Tone.Warn); }
        })).ConfigureAwait(false);
        if (source.Epoch != epoch) { throw Invalid("Session modifiée pendant le diagnostic."); }
        var opens = ports.Where(p => p.State == "open").Select(p => p.Service).ToArray();
        var summary = opens.Length > 0 ? "Ports ouverts : " + string.Join(", ", opens)
            : presence.Answered == true ? "Le ping répond ; aucun port de gestion ouvert." : "Aucun port ouvert ni réponse au ping : poste hors réseau ou trafic filtré, sans conclusion sur son arrêt.";
        return new(id.ToString("D"), computer.Name, address.ToString(), SearchTexts.Presence(presence, source.Clock.GetUtcNow()), [.. ports], summary, opens.Length > 0 ? Tone.Ok : Tone.Warn);
    }
}
