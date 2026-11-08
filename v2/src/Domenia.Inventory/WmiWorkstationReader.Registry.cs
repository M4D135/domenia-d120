using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class WmiWorkstationReader
{
    private static RegistryReading Registry(CimSession session, string key, string? name, RegistryMethod method) =>
        session.ReadRegistry(new(InventoryRegistry.Machine, key, name, method));

    private static CimReading RegistryAccess(string category, RegistryReading reading) => new(category, reading.Status, reading.Detail, reading.DurationMs,
        reading.Found ? [new WmiInstance(new Dictionary<string, object?>())] : []) { AuthenticationRejected = reading.AuthenticationRejected };

    private static InventorySnapshot ReadUpdateRegistry(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var server = Registry(session, InventoryRegistry.UpdatePolicy, "WUServer", RegistryMethod.String);
        var applied = Registry(session, InventoryRegistry.UpdatePolicy + @"\AU", "UseWUServer", RegistryMethod.Dword);
        var last = Registry(session, InventoryRegistry.UpdateInstall, "LastSuccessTime", RegistryMethod.String);
        AddAccess(access, session, InventoryCategories.Updates, RegistryAccess(InventoryCategories.Updates, server), RegistryAccess(InventoryCategories.Updates, applied), RegistryAccess(InventoryCategories.Updates, last));
        token.ThrowIfCancellationRequested();
        if (!server.Answered && !applied.Answered && !last.Answered) { return current with { Updates = null }; }
        var use = applied.Answered && !applied.Found ? false : applied.Flag;
        var known = server.Answered && applied.Answered && use is not null;
        var address = WsusAddress(server.Text);
        var reported = last.Text is { Length: > 0 and <= 128 } value && !value.Any(char.IsControl)
            && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out _) ? value.Trim() : null;
        var date = ExplicitOffsetDate(reported);
        if (!known || last.Found && date is null)
        { Incomplete(access, InventoryCategories.Updates, "Configuration ou date partiellement établie ; aucune date sans fuseau n’est convertie arbitrairement."); }
        return current with { Updates = new(address, use,
            !known ? "Source de mises à jour non établie" : use == true ? "WSUS (stratégie déclarée)" : "Windows Update (stratégie déclarée)",
            date, reported is not null ? "Succeeded" : null) { PolicyRead = known, LastSuccessReported = date is null ? reported : null } };
    }

    internal static string? WsusAddress(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) { return null; }
        // The displayed server never contains URI credentials, a query token or a fragment.
        return Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" && uri.Host.Length > 0
            ? uri.GetComponents(UriComponents.SchemeAndServer, UriFormat.UriEscaped) : "Adresse déclarée illisible";
    }

    internal static DateTimeOffset? ExplicitOffsetDate(string? value)
    {
        if (value is null || !(value.EndsWith('Z') || value.Length >= 6 && value[^6] is '+' or '-' && value[^3] == ':')) { return null; }
        return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var result) ? result : null;
    }

    private static InventorySnapshot ReadFirewall(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var profiles = ImmutableArray.CreateBuilder<FirewallProfile>();
        var reads = new List<CimReading>();
        var connections = session.Read(InventoryCategories.Firewall, @"root\StandardCimv2", "SELECT Name, InterfaceAlias, NetworkCategory FROM MSFT_NetConnectionProfile", 64);
        reads.Add(connections);
        foreach (var (key, label, category) in new[] { ("DomainProfile", "Domaine", 2), ("StandardProfile", "Privé", 1), ("PublicProfile", "Public", 0) })
        {
            var local = Registry(session, InventoryRegistry.LocalFirewall + key, "EnableFirewall", RegistryMethod.Dword);
            var policy = Registry(session, InventoryRegistry.PolicyFirewall + key, "EnableFirewall", RegistryMethod.Dword);
            reads.Add(RegistryAccess(InventoryCategories.Firewall, local)); reads.Add(RegistryAccess(InventoryCategories.Firewall, policy));
            var policyRead = policy.Answered && (!policy.Found || policy.Flag is not null);
            var policyFlag = policy.Flag;
            if (key == "StandardProfile")
            {
                var modern = Registry(session, InventoryRegistry.PolicyFirewall + "PrivateProfile", "EnableFirewall", RegistryMethod.Dword);
                reads.Add(RegistryAccess(InventoryCategories.Firewall, modern));
                policyRead = policyRead && modern.Answered && (!modern.Found || modern.Flag is not null)
                    && !(modern.Found && policy.Found && modern.Flag != policy.Flag);
                policyFlag = modern.Found ? modern.Flag : policy.Flag;
            }
            profiles.Add(new(label, local.Flag, policyFlag,
                [.. connections.Instances.Where(r => r.Int("NetworkCategory") == category).Select(r => r.Text("InterfaceAlias") ?? r.Text("Name") ?? "Connexion non identifiée")])
                { PolicyRead = policyRead, ConnectionsRead = connections.Status is SourceStatus.Ok or SourceStatus.Empty, Source = "Registre FirewallPolicy" });
        }
        AddAccess(access, session, InventoryCategories.Firewall, [.. reads]); token.ThrowIfCancellationRequested();
        if (profiles.Any(p => p.EffectiveEnabled is null))
        { Incomplete(access, InventoryCategories.Firewall, "Activation d’au moins un profil non établie ; une stratégie refusée ne devient pas une stratégie absente."); }
        return current with { Firewall = profiles.ToImmutable() };
    }

    private static InventorySnapshot ReadReboot(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var cbs = Registry(session, InventoryRegistry.CbsPending, null, RegistryMethod.Keys);
        var update = Registry(session, InventoryRegistry.UpdatePending, null, RegistryMethod.Keys);
        var rename = Registry(session, InventoryRegistry.SessionManager, "PendingFileRenameOperations", RegistryMethod.Strings);
        AddAccess(access, session, InventoryCategories.Reboot, RegistryAccess(InventoryCategories.Reboot, cbs), RegistryAccess(InventoryCategories.Reboot, update), RegistryAccess(InventoryCategories.Reboot, rename));
        token.ThrowIfCancellationRequested();
        var confirmed = ImmutableArray.CreateBuilder<string>(); var partial = ImmutableArray.CreateBuilder<string>();
        if (cbs.Answered && cbs.Found) { confirmed.Add("Maintenance Windows (CBS)"); }
        if (update.Answered && update.Found) { confirmed.Add("Windows Update"); }
        if (rename.Answered && rename.Strings.Any(s => !string.IsNullOrWhiteSpace(s))) { partial.Add("Opérations sur des fichiers en attente"); }
        return current with { PendingReboot = new(confirmed.ToImmutable(), partial.ToImmutable())
            { Complete = new[] { cbs, update, rename }.All(r => r.Status is SourceStatus.Ok or SourceStatus.Empty) } };
    }

    private static InventorySnapshot ReadSite(CimSession session, InventorySnapshot current, List<SourceAccess> access, CancellationToken token)
    {
        var configured = Registry(session, InventoryRegistry.Netlogon, "SiteName", RegistryMethod.String);
        var dynamic = Registry(session, InventoryRegistry.Netlogon, "DynamicSiteName", RegistryMethod.String);
        AddAccess(access, session, InventoryCategories.Site, RegistryAccess(InventoryCategories.Site, configured), RegistryAccess(InventoryCategories.Site, dynamic));
        token.ThrowIfCancellationRequested();
        // A refusal of the configured site cannot be replaced by a possibly overridden dynamic site.
        var site = configured.Answered ? !string.IsNullOrWhiteSpace(configured.Text) ? configured.Text : dynamic.Text : null;
        return current with { Site = site, Proxy = null };
    }
}
