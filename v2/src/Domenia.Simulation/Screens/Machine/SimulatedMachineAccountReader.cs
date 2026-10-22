using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Workstation account screen in simulation (docs/ops/schema.md § 15): workstations of the fictitious directory (as the session
/// sees it, writes of the session applied) and a deterministic access trial. The trial answers from the directory only: the
/// workstation must exist and have answered the initial presence round (or never been measured) and be enabled; a local account
/// of this workstation is accepted, a local account of another one or an unknown account is refused, a disabled, locked or expired
/// account is « restricted », and a domain account is administrator through the groups of the kind of computer (nested groups
/// included): GG-Admins-Postes for a workstation, GG-Admins-Serveurs for a server of OU=Serveurs, and for every computer Admins du
/// domaine or Administrateurs (only these two, and Administrateurs de l’entreprise, for a domain controller). No password is asked
/// nor checked; nothing is contacted.
/// </summary>
public sealed class SimulatedMachineAccountReader : IMachineAccountReader
{
    private static readonly string[] DomainAdminGroups = ["Admins du domaine", "Administrateurs"];
    private static readonly string[] ControllerAdminGroups = ["Admins du domaine", "Administrateurs", "Administrateurs de l’entreprise"];

    private readonly SimulatedDirectorySource source;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedMachineAccountReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public async Task<MachineWorkstation?> FindWorkstationAsync(string computer, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(computer);
        await source.SimulateScreenLatencyAsync("machine/find", 30, 90, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var found = Find(directory, computer);
        return found is null ? null : View(directory, found);
    }

    public async Task<ImmutableArray<MachineWorkstation>> SearchWorkstationsAsync(string text, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        await source.SimulateScreenLatencyAsync("machine/search", 40, 120, cancellationToken).ConfigureAwait(false);
        var term = FrenchText.Fold(text.Trim());
        if (term.Length == 0)
        {
            return [];
        }
        var directory = source.CurrentDirectory;
        return [.. directory.Computers
            .Select(c => (Computer: c, Name: FrenchText.Fold(c.Name)))
            .Where(x => x.Name.Contains(term, StringComparison.Ordinal))
            .OrderBy(x => x.Name.StartsWith(term, StringComparison.Ordinal) ? 0 : 1)
            .ThenBy(x => x.Computer.Name, StringComparer.OrdinalIgnoreCase)
            .Take(Math.Clamp(limit, 1, 50))
            .Select(x => View(directory, x.Computer))];
    }

    public async Task<MachineTrialObservation> ProbeAccessAsync(MachineProbeRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        await source.SimulateScreenLatencyAsync("machine/trial", 600, 1400, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var computer = Find(directory, request.Computer);
        if (computer is null)
        {
            return new MachineTrialObservation("TargetUnknown", null, null, null, null);
        }
        var workstation = View(directory, computer);
        var observation = Observation(computer.ObjectGuid);
        var reachable = !AdValues.IsDisabled(computer.UserAccountControl) && (observation?.Presence is not { HasReading: true } presence || presence.Answered == true);
        if (!reachable)
        {
            return new MachineTrialObservation("Timeout", "Le serveur RPC n’est pas disponible (0x800706BA).", "Network", null, workstation);
        }
        var caption = observation?.Inventory is { OsCaption: { Length: > 0 } os } ? os : computer.OperatingSystem is { } system ? "Microsoft " + system : null;
        var account = request.Account.Trim();
        var domain = directory.Domain;
        var slash = account.IndexOf('\\', StringComparison.Ordinal);
        DirectoryUser? user = null;
        if (slash > 0)
        {
            var prefix = account[..slash];
            var name = account[(slash + 1)..];
            if (string.Equals(prefix, computer.Name, StringComparison.OrdinalIgnoreCase))
            {
                // Local account of this workstation: the simulation cannot check its password; the local Administrators accept it.
                return new MachineTrialObservation("Observed", null, null, caption, workstation);
            }
            var domainPrefix = string.Equals(prefix, domain.NetbiosName, StringComparison.OrdinalIgnoreCase)
                || string.Equals(prefix, domain.DnsName, StringComparison.OrdinalIgnoreCase)
                || string.Equals(prefix, domain.DnsName.Split('.')[0], StringComparison.OrdinalIgnoreCase);
            if (!domainPrefix)
            {
                var other = directory.Computers.Any(c => string.Equals(c.Name, prefix, StringComparison.OrdinalIgnoreCase));
                return new MachineTrialObservation("AuthRejected", other ? "Compte local d’un autre poste." : "Domaine inconnu.", "CredentialsRejected", null, workstation);
            }
            user = directory.Users.FirstOrDefault(u => string.Equals(u.SamAccountName, name, StringComparison.OrdinalIgnoreCase));
        }
        else if (account.Contains('@', StringComparison.Ordinal))
        {
            var at = account.IndexOf('@', StringComparison.Ordinal);
            var name = account[..at];
            var suffix = account[(at + 1)..];
            user = directory.Users.FirstOrDefault(u => string.Equals(u.UserPrincipalName, account, StringComparison.OrdinalIgnoreCase))
                ?? (string.Equals(suffix, domain.DnsName, StringComparison.OrdinalIgnoreCase)
                    ? directory.Users.FirstOrDefault(u => string.Equals(u.SamAccountName, name, StringComparison.OrdinalIgnoreCase))
                    : null);
        }
        if (user is null)
        {
            return new MachineTrialObservation("AuthRejected", "Nom d’utilisateur ou mot de passe incorrect.", "CredentialsRejected", null, workstation);
        }
        var now = source.Clock.GetUtcNow();
        var expired = AdValues.FromFileTime(user.AccountExpires) is { } expires && expires <= now;
        var locked = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime).Lock == LockState.Locked;
        if (AdValues.IsDisabled(user.UserAccountControl) || locked || expired)
        {
            return new MachineTrialObservation("Failed", "Le compte est désactivé, verrouillé ou expiré.", "AccountState", null, workstation);
        }
        return IsAdministrator(directory, user, AdminGroupsOf(computer))
            ? new MachineTrialObservation("Observed", null, null, caption, workstation)
            : new MachineTrialObservation("Denied", "Accès refusé (0x80070005).", "AccessDenied", null, workstation);
    }

    /// <summary>Groups that administer this computer, by its kind (controller, server of OU=Serveurs, workstation).</summary>
    private static string[] AdminGroupsOf(DirectoryComputer computer)
    {
        if (AdValues.HasFlag(computer.UserAccountControl, AdValues.ServerTrustAccount))
        {
            return ControllerAdminGroups;
        }
        var server = DistinguishedName.Parse(computer.DistinguishedName).Any(n => string.Equals(n.Type, "OU", StringComparison.OrdinalIgnoreCase)
            && string.Equals(n.Value, "Serveurs", StringComparison.OrdinalIgnoreCase));
        return [server ? "GG-Admins-Serveurs" : "GG-Admins-Postes", .. DomainAdminGroups];
    }

    /// <summary>Member, directly or through nested groups, of one of the groups that administer the computer.</summary>
    private static bool IsAdministrator(DirectorySnapshot directory, DirectoryUser user, string[] adminGroups)
    {
        var groups = directory.Groups.ToDictionary(g => g.DistinguishedName, StringComparer.OrdinalIgnoreCase);
        var admins = directory.Groups.Where(g => adminGroups.Contains(g.Name, StringComparer.OrdinalIgnoreCase))
            .Select(g => g.DistinguishedName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var queue = new Queue<string>(user.MemberOf);
        while (queue.Count > 0 && seen.Count < 512)
        {
            var dn = queue.Dequeue();
            if (!seen.Add(dn))
            {
                continue;
            }
            if (admins.Contains(dn))
            {
                return true;
            }
            if (groups.TryGetValue(dn, out var group))
            {
                foreach (var parent in group.MemberOf)
                {
                    queue.Enqueue(parent);
                }
            }
        }
        return false;
    }

    private static DirectoryComputer? Find(DirectorySnapshot directory, string computer)
    {
        var text = computer.Trim();
        var key = MachineAccountRules.MachineKey(text);
        if (key is null)
        {
            return null;
        }
        return directory.Computers.FirstOrDefault(c => string.Equals(c.DnsHostName, text, StringComparison.OrdinalIgnoreCase))
            ?? directory.Computers.FirstOrDefault(c => string.Equals(c.Name, key, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Reading of the initial presence round (the round of the generated world: no read and no delay of the home page).</summary>
    private WorkstationObservation? Observation(Guid id) =>
        source.World.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == id);

    private MachineWorkstation View(DirectorySnapshot directory, DirectoryComputer computer)
    {
        var presence = Observation(computer.ObjectGuid)?.Presence;
        var state = presence is { HasReading: true }
            ? presence.Answered == true
                ? new MachinePresence("online", "En ligne au dernier relevé", Tone.Ok, presence.CheckedAt)
                : new MachinePresence("silent", "Sans réponse au dernier relevé", Tone.Warn, presence.CheckedAt)
            : new MachinePresence("unknown", "Présence jamais relevée", Tone.Off, null);
        return new MachineWorkstation(
            computer.ObjectGuid, computer.Name, computer.DnsHostName, computer.DistinguishedName, PathOf(directory.Domain.DnsName, computer.DistinguishedName),
            computer.OperatingSystem, !AdValues.IsDisabled(computer.UserAccountControl), state);
    }

    /// <summary>« example.local › Postes › Paris » for the container of the object.</summary>
    private static string PathOf(string dnsName, string dn)
    {
        var names = DistinguishedName.Parse(dn);
        var containers = names.Skip(1).TakeWhile(n => !string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase)).Select(n => n.Value).Reverse();
        return string.Join(FrenchText.PathSeparator, new[] { dnsName }.Concat(containers));
    }
}
