using System.Collections.Immutable;
using System.Net;
using System.Net.Sockets;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    internal Func<string, CancellationToken, Task<ImmutableArray<DiagCheck>>>? DiagnosticNetworkOverride { get; init; }

    public async Task<DiagnosticResult> DiagnosticAsync(string dn, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        var began = source.Clock.GetTimestamp();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(PosteDiagnostics.BudgetSeconds), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var local = await NetworkAsync(dn, stop.Token).ConfigureAwait(false);
        var host = local.Computer.DnsHostName!;
        using var access = await AdWorkstationAccess.AcquireAsync(source, host, stop.Token).ConfigureAwait(false);
        var checks = new List<DiagCheck>();
        void Add(DiagCheck check) { checks.Add(check); progress?.Report(new(checks.Count, 15, PosteDiagnostics.CheckLabel(check.Check))); }
        var network = DiagnosticNetworkOverride is { } injected ? await injected(host, stop.Token).ConfigureAwait(false) : await DiagnosticNetworkAsync(local, stop.Token).ConfigureAwait(false);
        foreach (var row in network) { Add(row); }
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        var reader = InventoryReader(access); InventorySnapshot? inventory = null; var busy = false;
        try
        {
            if (!stop.IsCancellationRequested)
            { inventory = await reader.ReadAsync(host, WorkstationReading.Diagnostic, null, stop.Token, access.Credential).ConfigureAwait(false); }
        }
        catch (OperationCanceledException) { /* Only the checks already received are retained. */ }
        catch (DomeniaOperationException ex) when (ex.Code == "machine.busy") { busy = true; }
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        var rejected = inventory?.Access.Any(a => a.AuthenticationRejected) == true;
        if (rejected || inventory?.Access.Any(a => a.Status == SourceStatus.Refused) == true) { access.Refused(host, "poste.diagnostic", rejected); }
        var confirmed = inventory is not null && WorkstationIdentity.Matches(local.Computer, inventory.ReportedName);
        var foreign = inventory?.ReportedName is not null && !confirmed;
        var transport = access.Settings.Options.UseWinRm ? "WinRM / Kerberos" : "DCOM";
        var system = inventory?.Access.FirstOrDefault(a => a.Category == InventoryCategories.System);
        Add(new("Session CIM", rejected ? "REFUSE" : foreign ? "ERREUR" : confirmed ? "OK" : busy ? "INCONNU" : Code(system?.Status), transport, system?.DurationMs ?? 0,
            foreign ? "Le nom Windows ne correspond pas au compte AD ; autres accès authentifiés suspendus." : confirmed ? "Nom Windows relu et conforme au compte ordinateur ; les autres sources sont qualifiées séparément." : busy ? "Des lectures natives précédentes se terminent encore ; aucun nouvel essai envoyé." : system?.Detail ?? "Non tenté : arrêt avant la lecture CIM."));
        if (confirmed && inventory is not null)
        {
            Add(new("Systeme", inventory.Os is { Caption.Length: > 0, Version.Length: > 0 } ? "OK" : Code(system?.Status, complete: false), transport, 0,
                inventory.Os is { Caption.Length: > 0, Version.Length: > 0 } os ? os.Caption + " " + os.Version : "Nom ou version du système non lus."));
            var volume = inventory.Volumes.SingleOrDefault(); var disk = inventory.Access.FirstOrDefault(a => a.Category == InventoryCategories.Volumes);
            var valid = volume?.SizeBytes is > 0 && volume.FreeBytes is >= 0 && volume.FreeBytes <= volume.SizeBytes;
            var free = valid ? 100d * volume!.FreeBytes!.Value / volume.SizeBytes!.Value : (double?)null;
            Add(new("Disque systeme", free is { } pct ? pct < 10 ? "ERREUR" : "OK" : Code(disk?.Status, complete: false), transport, disk?.DurationMs ?? 0,
                free is { } percent ? FrenchText.Percent(percent) + " libres sur " + volume!.Id + " (volume système déclaré par Windows)." : disk?.Detail ?? "Volume système non lu ; aucune lettre supposée."));
            var reboot = inventory.Access.FirstOrDefault(a => a.Category == InventoryCategories.Reboot); var pending = inventory.PendingReboot;
            Add(new("Redemarrage en attente", pending?.Confirmed.Length > 0 ? "ERREUR" : pending is { Complete: true, Partial.IsEmpty: true } ? "OK" : "INCONNU", "Registre en lecture seule", reboot?.DurationMs ?? 0,
                pending?.Confirmed.Length > 0 ? string.Join(", ", pending.Confirmed) : pending is { Complete: true, Partial.IsEmpty: true } ? "Aucun indicateur dans les trois sources lues." : "Indicateurs incomplets ou seulement possibles ; aucune absence confirmée."));
        }
        else
        {
            foreach (var check in new[] { "Systeme", "Disque systeme", "Redemarrage en attente" })
            { Add(new(check, "IGNORE", transport, 0, "Données non attribuées : identité Windows non confirmée ou diagnostic arrêté.")); }
        }
        foreach (var (kind, label, method, seconds) in new[]
        {
            (DiagnosticTransport.WinRm, "WinRM", "WS-Management / Kerberos", 6),
            (DiagnosticTransport.Smb, "Partage C$", "SMB", 6),
            (DiagnosticTransport.TaskScheduler, "Transport Task Scheduler", "Task Scheduler RPC", 8),
        })
        {
            access.EnsureCurrent(); EnsureEpoch(local.Epoch);
            var left = TimeSpan.FromSeconds(PosteDiagnostics.BudgetSeconds) - source.Clock.GetElapsedTime(began);
            var disabled = kind == DiagnosticTransport.WinRm && !access.Settings.UseCim || kind == DiagnosticTransport.TaskScheduler && !access.Settings.UseTaskFallback;
            if (stop.IsCancellationRequested || left <= TimeSpan.Zero || rejected || foreign || disabled)
            { Add(new(label, "IGNORE", method, 0, rejected ? "Authentification rejetée ; aucun autre essai." : foreign ? "Identité Windows différente ; contrôle non envoyé." : disabled ? "Contrôle désactivé par la configuration." : "Non tenté : arrêt ou budget global atteint.")); continue; }
            var budget = left < TimeSpan.FromSeconds(seconds) ? left : TimeSpan.FromSeconds(seconds);
            SourceAccess result;
            try { result = await reader.ReadDiagnosticTransportAsync(host, kind, budget, stop.Token, access.Credential).ConfigureAwait(false); }
            catch (OperationCanceledException) { Add(new(label, "IGNORE", method, 0, "Non tenté : diagnostic arrêté.")); continue; }
            catch (DomeniaOperationException ex) when (ex.Code == "machine.busy")
            { Add(new(label, "INCONNU", method, 0, "Des lectures natives précédentes se terminent encore ; aucun nouvel essai envoyé.")); continue; }
            access.EnsureCurrent(); EnsureEpoch(local.Epoch);
            if (result.Status == SourceStatus.Refused || result.AuthenticationRejected) { access.Refused(host, "poste.diagnostic", result.AuthenticationRejected); }
            rejected |= result.AuthenticationRejected;
            Add(new(label, Code(result.Status), method, result.DurationMs, result.Detail));
        }
        Add(new("Transport PsExec", "IGNORE", "Outil externe", 0, access.Settings.UsePsExecFallback
            ? "Aucun exécutable PsExec approuvé configuré dans cette session ; aucun service distant installé." : "Repli PsExec désactivé par la configuration."));
        EnsureEpoch(local.Epoch); access.EnsureCurrent();
        return PosteDiagnostics.Verdict(local.Computer.Name, checks, source.Clock.GetUtcNow(), (int)source.Clock.GetElapsedTime(began).TotalMilliseconds, source.Zone);
    }

    private static string Code(SourceStatus? status, bool complete = true) => status switch
    {
        SourceStatus.Ok or SourceStatus.Empty when complete => "OK", SourceStatus.Refused => "REFUSE", SourceStatus.Unreachable => "INJOIGNABLE",
        SourceStatus.Skipped or SourceStatus.Interrupted or null => "IGNORE", SourceStatus.Error => "ERREUR", _ => "INCONNU",
    };

    private async Task<ImmutableArray<DiagCheck>> DiagnosticNetworkAsync(LocalPoste local, CancellationToken token)
    {
        var host = local.Computer.DnsHostName!;
        async Task<DiagCheck> DnsAsync()
        {
            var began = source.Clock.GetTimestamp();
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(4), source.Clock);
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(token, limit.Token);
            try
            {
                var addresses = await Dns.GetHostAddressesAsync(host, budget.Token).ConfigureAwait(false);
                return new("Resolution DNS", addresses.Length > 0 ? "OK" : "ERREUR", "DNS", (int)source.Clock.GetElapsedTime(began).TotalMilliseconds,
                    addresses.Length > 0 ? host + " → " + string.Join(", ", addresses.Take(16).Select(a => a.ToString())) + " ; l’adresse ne prouve pas l’identité Windows." : "Aucune adresse reçue.");
            }
            catch (OperationCanceledException) { return new("Resolution DNS", token.IsCancellationRequested ? "IGNORE" : "INCONNU", "DNS", (int)source.Clock.GetElapsedTime(began).TotalMilliseconds, "Résolution arrêtée ou délai atteint ; aucune conclusion sur l’existence du nom."); }
            catch (Exception ex) when (ex is SocketException or TimeoutException)
            { return new("Resolution DNS", ex is TimeoutException ? "INCONNU" : "ERREUR", "DNS", (int)source.Clock.GetElapsedTime(began).TotalMilliseconds, "Résolution non concluante ; aucune adresse reçue."); }
        }
        async Task<DiagCheck> IcmpAsync()
        {
            var began = source.Clock.GetTimestamp();
            try
            {
                var ping = await PingAsync(local, token).ConfigureAwait(false);
                return new("Ping", ping.Answered switch { true => "OK", false => "INJOIGNABLE", _ => "INCONNU" }, "ICMP", (int)source.Clock.GetElapsedTime(began).TotalMilliseconds, ping.Source);
            }
            catch (OperationCanceledException) { return new("Ping", "IGNORE", "ICMP", 0, "Écho arrêté ; présence inconnue."); }
        }
        async Task<DiagCheck> TcpAsync(int port)
        {
            var began = source.Clock.GetTimestamp();
            var open = await PortAsync(host, port, TimeSpan.FromMilliseconds(Math.Min(configuration.PortTimeoutMs, 2000)), token).ConfigureAwait(false);
            return new("TCP " + port, open switch { true => "OK", false => "INJOIGNABLE", _ => "IGNORE" }, "TCP", (int)source.Clock.GetElapsedTime(began).TotalMilliseconds,
                open == true ? "Connexion TCP acceptée ; aucun protocole ni droit prouvé." : open == false ? "Connexion non établie : fermeture, filtrage ou absence de réponse." : "Contrôle arrêté.");
        }
        return [.. await Task.WhenAll(new[] { DnsAsync(), IcmpAsync() }.Concat(new[] { 135, 445, 3389, 5985, 5986 }.Select(TcpAsync))).ConfigureAwait(false)];
    }
}
