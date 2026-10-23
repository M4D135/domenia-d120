using System.Collections.Immutable;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Xml;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using ReadState = Domenia.Core.ReadState;

namespace Domenia.Ad;

public sealed partial class AdAuditReader
{
    internal Func<string, RemoteProbeCredential?, IAdConnection>? ControllerFactory { get; init; }
    internal Func<string, WmiWorkstationReader>? WorkstationFactory { get; init; }
    private async Task<AdReadAccess> OnController(string host, CancellationToken token) => await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, host, token,
        selected => ControllerFactory?.Invoke(host, selected) ?? CreateController(host, selected)).ConfigureAwait(false);
    private IAdConnection CreateController(string host, RemoteProbeCredential? selected)
    {
        if (source.Connection is not AdConnection native) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Transport de comparaison par contrôleur indisponible."); }
        NetworkCredential? credential = null;
        try
        {
            if (selected is not null)
            {
                var name = CredentialRules.Parse(selected.Account); credential = new(name.Form == AccountNameForm.Upn ? selected.Account : name.Name, selected.Password!, name.Form == AccountNameForm.Upn ? "" : name.Authority);
            }
            using var chosen = native.ForRead(credential); return chosen.ForServer(host, TimeSpan.FromSeconds(5));
        }
        finally { if (credential is not null) { using var empty = new System.Security.SecureString(); credential.SecurePassword = empty; } }
    }
    private async Task<ImmutableArray<string>> ControllersChosen(IReadOnlyList<string> controllers, CancellationToken token)
    {
        var valid = AuditControllerRules.RequireControllers(controllers);
        if (valid.Any(n => !n.Contains('.') || IPAddress.TryParse(n, out _))) { throw Invalid("Sélectionnez le nom DNS complet d’un contrôleur du domaine."); }
        return AuditControllerRules.RequireKnown(valid, await ControllersAsync(token).ConfigureAwait(false));
    }
    public async Task<ControllerListRead> ControllersAsync(CancellationToken cancellationToken)
    {
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, cancellationToken).ConfigureAwait(false);
        var root = await access.RootDseAsync(cancellationToken).ConfigureAwait(false);
        var rows = await access.SearchAsync(Request(root.DefaultNamingContext, "(&(objectClass=computer)(userAccountControl:1.2.840.113556.1.4.803:=8192))", AdSearchScope.Subtree,
            [.. IdentityAttributes, "operatingSystem", "msDS-isRODC", "serverReferenceBL", "userAccountControl"], 101, 20), cancellationToken).ConfigureAwait(false);
        var result = ImmutableArray.CreateBuilder<ControllerRead>();
        foreach (var e in rows.Take(100))
        {
            var host = e.String("dNSHostName"); if (e.Guid("objectGUID") is null || Kind(e) != AuditObjectKind.Computer || host is null || !AuditControllerRules.IsHostName(host) || !host.Contains('.') || IPAddress.TryParse(host, out _)
                || (e.Int("userAccountControl") & AdValues.ServerTrustAccount) != AdValues.ServerTrustAccount) { throw Incomplete(); }
            string? site = null; var server = e.String("serverReferenceBL");
            if (server is not null)
            {
                var parts = DistinguishedName.Parse(server); if (parts.Length > 3 && parts[1].Value.Equals("Servers", StringComparison.OrdinalIgnoreCase)) { site = parts[2].Value; }
            }
            result.Add(new(e.String("name") ?? host.Split('.')[0], host, e.String("operatingSystem"), site, Boolean(e, "msDS-isRODC") == true || (e.Int("userAccountControl") & 0x04000000) != 0, e.DistinguishedName));
        }
        string? pdc = null; string? error = null;
        try
        {
            var domain = await One(access, root.DefaultNamingContext, ["fSMORoleOwner"], cancellationToken).ConfigureAwait(false);
            var owner = domain?.String("fSMORoleOwner"); if (owner is null) { throw Incomplete(); }
            var server = DistinguishedName.Parent(owner) ?? throw Incomplete();
            var entry = await One(access, server, ["dNSHostName"], cancellationToken, forest: true).ConfigureAwait(false);
            var name = entry?.String("dNSHostName"); if (name is null || !result.Any(r => r.DnsHostName.Equals(name, StringComparison.OrdinalIgnoreCase))) { throw Incomplete(); } pdc = name;
        }
        catch (Exception ex) when (Recoverable(ex)) { error = Message(ex); }
        return new(result.ToImmutable(), rows.Count > 100, pdc, error, Controller(access), Now);
    }
    private static async Task<(ImmutableArray<string> Addresses, string? Error)> Addresses(string host, CancellationToken token)
    {
        try { var addresses = await Dns.GetHostAddressesAsync(host, token).WaitAsync(TimeSpan.FromSeconds(3), token).ConfigureAwait(false); return ([.. addresses.Select(a => a.ToString()).Distinct().Take(32)], null); }
        catch (Exception ex) when (ex is SocketException or TimeoutException) { return ([], "Résolution DNS indisponible ou délai de trois secondes atteint."); }
    }
    private static async Task<bool?> Port(string host, int port, CancellationToken token)
    {
        using var client = new TcpClient();
        try { await client.ConnectAsync(host, port, token).AsTask().WaitAsync(TimeSpan.FromSeconds(2), token).ConfigureAwait(false); return true; }
        catch (SocketException) { return false; } catch (TimeoutException) { return null; }
    }
    public async Task<ControllerProbesRead> ProbeControllersAsync(IReadOnlyList<string> controllers, string? pdc, CancellationToken cancellationToken)
    {
        var epoch = source.Epoch; var names = await ControllersChosen(controllers, cancellationToken).ConfigureAwait(false);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(100)); var token = stop.Token;
        var result = ImmutableArray.CreateBuilder<ControllerProbeRead>();
        foreach (var host in names)
        {
            var dns = await Addresses(host, token).ConfigureAwait(false); var ldap = await Port(host, 389, token).ConfigureAwait(false); var kerberos = await Port(host, 88, token).ConfigureAwait(false);
            var local = Now; AdRootDse? root = null; var state = ReadState.NotRead; string? error = null; var replication = ReadState.NotRead; string? repError = null; ImmutableArray<ReplicationNeighborRead> neighbors = [];
            try
            {
                using var access = await OnController(host, token).ConfigureAwait(false); root = await access.RootDseAsync(token).ConfigureAwait(false);
                if (!root.DnsHostName.Equals(host, StringComparison.OrdinalIgnoreCase)) { throw Incomplete(); }
                state = ReadState.Read;
                var entry = await One(access, root.DefaultNamingContext, ["msDS-NCReplInboundNeighbors"], token).ConfigureAwait(false) ?? throw Incomplete();
                var fragments = entry.Strings("msDS-NCReplInboundNeighbors");
                if (fragments.Count > 1000 || fragments.Sum(f => (long)f.Length) > 1048576) { throw Incomplete(); }
                var parsed = fragments.Select(AuditControllerRules.ParseNeighbor).ToArray();
                if (parsed.Any(n => n is null)) { throw Incomplete(); }
                neighbors = [.. parsed.OfType<ReplicationNeighborRead>()];
                replication = fragments.Count == 0 ? ReadState.NotRead : ReadState.Read;
                if (fragments.Count == 0) { repError = "Aucun voisin retourné pour la partition du domaine ; absence de réplication non déduite."; }
            }
            catch (Exception ex) when (Recoverable(ex)) { if (root is null) { state = State(ex); error = Message(ex); } replication = State(ex); repError = Message(ex); }
            Current(epoch); result.Add(new(host, dns.Addresses, dns.Error, ldap, kerberos, state, error, root?.CurrentTime, local, root?.IsSynchronized, root?.HighestCommittedUsn, replication, repError, neighbors));
            if (state == ReadState.Refused || replication == ReadState.Refused) { break; }
        }
        var domain = await Local(token).ConfigureAwait(false); var srv = await AdAuditDns.SrvAsync("_ldap._tcp.dc._msdcs." + domain.Domain.DnsName, token).ConfigureAwait(false); Current(epoch);
        return new(result.ToImmutable(), srv.Names, srv.State, srv.Error, pdc, Now);
    }
    public async Task<ControllerServicesReads> ControllerServicesAsync(IReadOnlyList<string> controllers, int budgetSeconds, CancellationToken cancellationToken)
    {
        if (budgetSeconds is < 1 or > 280) { throw Invalid("Budget des services limité à 280 secondes."); }
        var names = await ControllersChosen(controllers, cancellationToken).ConfigureAwait(false); var start = source.Clock.GetTimestamp();
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(budgetSeconds)); var token = stop.Token;
        var results = ImmutableArray.CreateBuilder<ControllerServicesRead>();
        foreach (var host in names)
        {
            try
            {
                using var machine = await AdWorkstationAccess.AcquireAsync(source, host, token).ConfigureAwait(false);
                var read = await (WorkstationFactory?.Invoke(host) ?? machine.InventoryReader()).ReadWmiQueryAsync(host, new(@"root\cimv2", "Win32_Service", "Name='NTDS' OR Name='Netlogon' OR Name='Kdc' OR Name='W32Time' OR Name='ADWS' OR Name='DNS' OR Name='DFSR' OR Name='NtFrs'", 9), token, machine.Credential).ConfigureAwait(false);
                machine.EnsureCurrent(); if (read.AuthenticationRejected || read.Status == SourceStatus.Refused) { machine.Refused(host, "Services du contrôleur", read.AuthenticationRejected); }
                if (!string.Equals(read.ReportedName, host.Split('.')[0], StringComparison.OrdinalIgnoreCase)) { throw Incomplete(); }
                var rows = ReadRows(read); var services = rows.Select(r => new ServiceStateRead(Value(r, "Name") ?? "", Value(r, "State") ?? "Non lu", Value(r, "StartMode") ?? "Non lu")).ToImmutableArray();
                results.Add(new(host, SourceState(read.Status), read.Detail, services)); if (read.AuthenticationRejected) { break; }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { results.Add(new(host, ReadState.Unavailable, "Budget atteint ; services non lus.", [])); break; }
            catch (Exception ex) when (Recoverable(ex)) { results.Add(new(host, State(ex), Message(ex), [])); if (State(ex) == ReadState.Refused) { break; } }
        }
        return new(results.ToImmutable(), budgetSeconds, (long)source.Clock.GetElapsedTime(start).TotalMilliseconds, Now);
    }
    private static readonly string[] ComparisonAttributes = ["objectGUID", "objectSid", "name", "sAMAccountName", "userPrincipalName", "userAccountControl", "pwdLastSet", "lockoutTime", "description", "mail", "manager", "managedBy", "memberOf", "member", "whenCreated", "whenChanged"];
    public async Task<ObjectComparisonRead> CompareObjectAsync(AuditTarget target, IReadOnlyList<string> controllers, CancellationToken cancellationToken)
    {
        var names = await ControllersChosen(controllers, cancellationToken).ConfigureAwait(false); var result = ImmutableArray.CreateBuilder<ControllerReadingRead>();
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(100));
        foreach (var host in names)
        {
            try
            {
                using var access = await OnController(host, stop.Token).ConfigureAwait(false); var root = await access.RootDseAsync(stop.Token).ConfigureAwait(false);
                if (!root.DnsHostName.Equals(host, StringComparison.OrdinalIgnoreCase)) { throw Incomplete(); }
                var e = await Exact(access, target, [.. ComparisonAttributes, "msDS-ReplAttributeMetaData"], stop.Token).ConfigureAwait(false);
                var attributes = ImmutableDictionary.CreateBuilder<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase);
                foreach (var attribute in ComparisonAttributes) { attributes[attribute] = [.. e.Raw(attribute).Select(v => v is byte[] b ? Convert.ToHexString(b) : Convert.ToString(v, CultureInfo.InvariantCulture) ?? "")]; }
                var metadata = ParseMetadata(e.Strings("msDS-ReplAttributeMetaData")); result.Add(new(host, true, metadata.IsEmpty ? "Métadonnées de réplication non retournées." : null, attributes.ToImmutable(), metadata));
            }
            catch (Exception ex) when (Recoverable(ex) || ex is XmlException or FormatException) { result.Add(new(host, false, Message(ex), ImmutableDictionary<string, ImmutableArray<string>>.Empty, [])); if (State(ex) == ReadState.Refused) { break; } }
        }
        return new(target.Dn, target.Name, result.ToImmutable(), Now);
    }
    internal static ImmutableArray<ReplicationMetadataRead> ParseMetadata(IReadOnlyList<string> fragments)
    {
        if (fragments.Count > 2000 || fragments.Sum(f => (long)f.Length) > 1048576) { throw Incomplete(); }
        var result = ImmutableArray.CreateBuilder<ReplicationMetadataRead>(); var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var fragment in fragments)
        {
            using var reader = XmlReader.Create(new StringReader(fragment), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 65536 });
            var root = XElement.Load(reader);
            if (root.Name.LocalName is not ("DS_REPL_ATTR_META_DATA" or "DS_REPL_ATTR_META_DATAW")
                || root.Elements().GroupBy(e => e.Name.LocalName, StringComparer.Ordinal).Any(g => g.Count() != 1)) { throw Incomplete(); }
            string? Read(string key) => root.Elements().SingleOrDefault(e => e.Name.LocalName == key)?.Value;
            var name = Read("pszAttributeName");
            if (name is null || name.Length > 256 || !names.Add(name) || !int.TryParse(Read("dwVersion"), out var version) || !long.TryParse(Read("usnLocalChange"), out var local) || !long.TryParse(Read("usnOriginatingChange"), out var origin) || version < 0 || local < 0 || origin < 0) { throw Incomplete(); }
            var time = DateTimeOffset.TryParse(Read("ftimeLastOriginatingChange"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) ? date : (DateTimeOffset?)null;
            result.Add(new(name, version, time, Read("pszLastOriginatingDsaDN") ?? Read("uuidLastOriginatingDsaInvocationID"), local, origin));
        }
        return result.ToImmutable();
    }
}
