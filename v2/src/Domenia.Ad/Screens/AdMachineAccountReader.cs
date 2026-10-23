using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>Local workstation picker and an explicit, single CIM credential trial.</summary>
public sealed class AdMachineAccountReader(AdDirectorySource source) : IMachineAccountReader
{
    public Task<MachineWorkstation?> FindWorkstationAsync(string computer, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var directory = source.CurrentDirectory;
        if (directory is null) { return Task.FromResult<MachineWorkstation?>(null); }
        var requested = computer.Trim().TrimEnd('.');
        var key = MachineAccountRules.MachineKey(requested);
        var candidates = directory.Computers.Where(c => string.Equals(c.DnsHostName, requested, StringComparison.OrdinalIgnoreCase)
            || (!requested.Contains('.') && key is not null && string.Equals(c.Name, key, StringComparison.OrdinalIgnoreCase))).Take(2).ToArray();
        return Task.FromResult(candidates.Length == 1 ? View(directory, candidates[0]) : null);
    }

    public Task<ImmutableArray<MachineWorkstation>> SearchWorkstationsAsync(string text, int limit, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var directory = source.CurrentDirectory;
        var term = FrenchText.Fold(text.Trim());
        if (directory is null || term.Length == 0) { return Task.FromResult(ImmutableArray<MachineWorkstation>.Empty); }
        return Task.FromResult(directory.Computers.Where(c => FrenchText.Fold(c.Name).Contains(term, StringComparison.Ordinal))
            .OrderBy(c => FrenchText.Fold(c.Name).StartsWith(term, StringComparison.Ordinal) ? 0 : 1)
            .ThenBy(c => c.Name, StringComparer.OrdinalIgnoreCase).Take(Math.Clamp(limit, 1, 50))
            .Select(c => View(directory, c)).ToImmutableArray());
    }

    public async Task<MachineTrialObservation> ProbeAccessAsync(MachineProbeRequest request, CancellationToken cancellationToken)
    {
        var epoch = source.Epoch;
        var workstation = await FindWorkstationAsync(request.Computer, cancellationToken).ConfigureAwait(false);
        if (workstation is null) { return new("TargetUnknown", "Choisissez un poste connu de l’annuaire local.", "Target", null, null); }
        if (request.Source != MachineAccountSource.Windows)
        {
            var known = source.KnownDomain;
            var check = CredentialRules.CheckContext(CredentialRules.Remote, request.Account, workstation.Name,
                new[] { known?.DnsName, known?.NetbiosName }.OfType<string>().ToArray());
            if (!check.Valid) { throw new DomeniaOperationException(AccountAccess.ContextRefused, check.Reason); }
        }
        using var connection = request.Source == MachineAccountSource.Connection && request.Password is null
            ? source.CopySessionCredential(epoch, request.Account) : null;
        if (request.Source == MachineAccountSource.Connection && request.Password is null)
        {
            if (connection?.Password is null)
            { return new("Failed", "Identité de connexion explicite indisponible ; aucun repli Windows.", "CredentialMissing", null, workstation); }
            request = request with { Password = connection.Password };
        }
        var answer = await new WmiMachineAccessProbe(source.Clock).ReadAsync(request, workstation, cancellationToken).ConfigureAwait(false);
        if (source.Epoch != epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant l’essai ; résultat écarté."); }
        return answer;
    }

    private MachineWorkstation View(DirectorySnapshot directory, DirectoryComputer computer)
    {
        var presence = source.CurrentObservations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid)?.Presence;
        var state = presence is { HasReading: true }
            ? presence.Answered == true ? new MachinePresence("online", "En ligne au dernier relevé", Tone.Ok, presence.CheckedAt)
                : new MachinePresence("silent", "Sans réponse au dernier relevé", Tone.Warn, presence.CheckedAt)
            : new MachinePresence("unknown", "Présence jamais relevée", Tone.Off, null);
        var containers = DistinguishedName.Parse(computer.DistinguishedName).Skip(1).TakeWhile(n => !string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase)).Select(n => n.Value).Reverse();
        return new(computer.ObjectGuid, computer.Name, computer.DnsHostName, computer.DistinguishedName,
            string.Join(FrenchText.PathSeparator, new[] { directory.Domain.DnsName }.Concat(containers)),
            computer.OperatingSystem, !AdValues.IsDisabled(computer.UserAccountControl), state);
    }
}
