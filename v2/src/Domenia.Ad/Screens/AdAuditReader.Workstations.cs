using System.Collections.Immutable;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdAuditReader
{
    private static ReadState SourceState(SourceStatus state) => state switch { SourceStatus.Ok => ReadState.Read, SourceStatus.Empty => ReadState.Empty,
        SourceStatus.Refused => ReadState.Refused, SourceStatus.Skipped => ReadState.NotRead, _ => ReadState.Unavailable };
    private static ImmutableArray<ImmutableDictionary<string, string?>> ReadRows(WorkstationWmiReading read)
    {
        if (read.Schema.Length > 64 || read.Rows.Length > 500 || read.Schema.Select(p => p.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != read.Schema.Length) { throw Incomplete(); }
        return [.. read.Rows.Select(row =>
        {
            if (row.Length != read.Schema.Length) { throw Incomplete(); }
            return read.Schema.Select((property, i) => (property.Name, Value: row[i])).ToImmutableDictionary(v => v.Name, v => v.Value, StringComparer.OrdinalIgnoreCase);
        })];
    }
    private static string? Value(IReadOnlyDictionary<string, string?> row, string field) => row.GetValueOrDefault(field);
    private static bool? Bit(IReadOnlyDictionary<string, string?> row, string field) => bool.TryParse(Value(row, field), out var b) ? b : null;
    internal static Guid? RsopGuid(string? text)
    {
        if (text is null || text.Length > 4096) { return null; }
        var match = Regex.Match(text, @"\{(?<id>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
        return match.Success && Guid.TryParse(match.Groups["id"].Value, out var id) ? id : Guid.TryParse(text, out id) ? id : null;
    }
    private async Task<DirectoryComputer> Machine(AdReadAccess access, AuditTarget target, CancellationToken token)
    {
        if (target.Kind != AuditObjectKind.Computer || target.ObjectGuid is null) { throw Invalid("Un ordinateur AD identifié est requis."); }
        var e = await Exact(access, target, AdDirectoryMapper.ComputerAttributes, token).ConfigureAwait(false);
        var computer = AdDirectoryMapper.Computer(e) ?? throw Incomplete();
        if (WorkstationIdentity.ExpectedName(computer) is null || computer.DnsHostName is null || !computer.DnsHostName.Contains('.') || IPAddress.TryParse(computer.DnsHostName, out _)) { throw Incomplete(); }
        return computer;
    }
    private async Task VerifyMachine(AdReadAccess access, AuditTarget target, DirectoryComputer before, string? reported, CancellationToken token)
    {
        if (!WorkstationIdentity.Matches(before, reported)) { throw Incomplete(); }
        var after = await Machine(access, target, token).ConfigureAwait(false);
        if (after.WhenCreated != before.WhenCreated || after.Sid != before.Sid || !string.Equals(after.DnsHostName, before.DnsHostName, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(after.SamAccountName, before.SamAccountName, StringComparison.OrdinalIgnoreCase)) { throw Incomplete(); }
    }
    public async Task<RsopRead> AppliedPoliciesAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(80)); var token = stop.Token;
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, target.Dn, token).ConfigureAwait(false);
        var computer = await Machine(access, target, token).ConfigureAwait(false); var host = computer.DnsHostName!;
        using var machine = await AdWorkstationAccess.AcquireAsync(source, host, token).ConfigureAwait(false); var reader = WorkstationFactory?.Invoke(host) ?? machine.InventoryReader();
        try
        {
            var first = await reader.ReadWmiQueryAsync(host, new(@"root\rsop\computer", "RSOP_GPO", null, 500), token, machine.Credential).ConfigureAwait(false);
            machine.EnsureCurrent();
            if (first.Status == SourceStatus.Refused || first.AuthenticationRejected) { machine.Refused(host, "Résultat GPO appliqué", first.AuthenticationRejected); }
            if (first.Status is not (SourceStatus.Ok or SourceStatus.Empty)) { return new(host, SourceState(first.Status), first.Detail, null, null, null, Now); }
            var second = await reader.ReadWmiQueryAsync(host, new(@"root\rsop\computer", "RSOP_GPLink", null, 500), token, machine.Credential).ConfigureAwait(false);
            machine.EnsureCurrent();
            if (second.Status == SourceStatus.Refused || second.AuthenticationRejected) { machine.Refused(host, "Liens du résultat GPO", second.AuthenticationRejected); }
            await VerifyMachine(access, target, computer, first.ReportedName, token).ConfigureAwait(false);
            if (!WorkstationIdentity.Matches(computer, second.ReportedName)) { throw Incomplete(); }
            var gpos = ReadRows(first).Select(r => new RsopGpoRead(RsopGuid(Value(r, "guidName") ?? Value(r, "id")), Value(r, "name"), Bit(r, "accessDenied"), Bit(r, "filterAllowed"), Bit(r, "enabled"))).ToImmutableArray();
            ImmutableArray<RsopLinkRead>? links = second.Status is SourceStatus.Ok or SourceStatus.Empty
                ? [.. ReadRows(second).Select(r => new RsopLinkRead(RsopGuid(Value(r, "GPO")), Value(r, "SOM"), long.TryParse(Value(r, "appliedOrder"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : null))] : null;
            return new(host, ReadState.Read, null, gpos, links, links is null ? second.Detail : null, Now);
        }
        catch (Exception ex) when (Recoverable(ex)) { return new(host, State(ex), Message(ex), null, null, null, Now); }
    }
    public async Task<MachineIdentityRead> MachineIdentityAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); stop.CancelAfter(TimeSpan.FromSeconds(45)); var token = stop.Token;
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, target.Dn, token).ConfigureAwait(false);
        var computer = await Machine(access, target, token).ConfigureAwait(false); var host = computer.DnsHostName!; var dns = await Addresses(host, token).ConfigureAwait(false); string? ptr = null; string? message = dns.Error;
        if (dns.Addresses.Length > 0)
        {
            try { ptr = (await Dns.GetHostEntryAsync(IPAddress.Parse(dns.Addresses[0])).WaitAsync(TimeSpan.FromSeconds(3), token).ConfigureAwait(false)).HostName; }
            catch (Exception ex) when (ex is SocketException or TimeoutException) { message = "Résolution directe reçue ; nom inverse non disponible."; }
        }
        var resolution = new DnsResolutionRead(dns.Addresses.Length > 0 ? ReadState.Read : ReadState.Unavailable, dns.Addresses, ptr, message);
        using var machine = await AdWorkstationAccess.AcquireAsync(source, host, token).ConfigureAwait(false);
        try
        {
            var read = await (WorkstationFactory?.Invoke(host) ?? machine.InventoryReader()).ReadWmiQueryAsync(host, new(@"root\cimv2", "Win32_ComputerSystem", null, 2), token, machine.Credential).ConfigureAwait(false);
            machine.EnsureCurrent(); if (read.Status == SourceStatus.Refused || read.AuthenticationRejected) { machine.Refused(host, "Identité Windows", read.AuthenticationRejected); }
            var rows = ReadRows(read);
            if (read.Status is SourceStatus.Ok && rows.Length != 1) { throw Incomplete(); }
            if (read.Status is not SourceStatus.Ok) { return new(host, resolution, new(SourceState(read.Status), null, null, null, read.Detail), Now); }
            await VerifyMachine(access, target, computer, read.ReportedName, token).ConfigureAwait(false);
            var name = Value(rows[0], "Name"); var domain = Value(rows[0], "Domain");
            if (!WorkstationIdentity.Matches(computer, name) || string.IsNullOrWhiteSpace(domain)) { throw Incomplete(); }
            return new(host, resolution, new(ReadState.Read, name, name is not null && domain is not null ? name + "." + domain : null, domain, null), Now);
        }
        catch (Exception ex) when (Recoverable(ex)) { return new(host, resolution, new(State(ex), null, null, null, Message(ex)), Now); }
    }
}
