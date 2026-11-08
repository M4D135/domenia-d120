using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
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
        await EnsureTrialTransportAsync(source, cancellationToken).ConfigureAwait(false);
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
        return await TrialAsync(source, request, workstation, epoch, cancellationToken, ProbeOverride).ConfigureAwait(false);
    }

    internal Func<MachineProbeRequest, MachineWorkstation, bool, CancellationToken, Task<MachineTrialObservation>>? ProbeOverride { get; init; }

    internal static async Task<MachineTrialObservation> TrialAsync(AdDirectorySource source, MachineProbeRequest request,
        MachineWorkstation workstation, long epoch, CancellationToken token,
        Func<MachineProbeRequest, MachineWorkstation, bool, CancellationToken, Task<MachineTrialObservation>>? probe = null)
    {
        var connectionIdentity = request.Source is MachineAccountSource.Windows or MachineAccountSource.Connection;
        using var connection = request.Source == MachineAccountSource.Connection && request.Password is null
            ? source.CopySessionCredential(epoch, request.Account) : null;
        if (request.Source == MachineAccountSource.Connection && request.Password is null)
        {
            if (connection?.Password is null)
                return new("Failed", "Identité de connexion explicite indisponible ; aucun repli Windows.", "CredentialMissing", null, workstation);
            request = request with { Password = connection.Password };
        }
        var local = CredentialRules.IsLocalAccount(request.Account, workstation.Name);
        if (connectionIdentity && !source.AdministrationForCredential(epoch, request.Account, "", request.Password, true).AllowsRemote
            && source.AdministrationPrincipalFor(epoch, request.Account, request.Password, true) is null)
        { await source.RefreshConnectionAdministrationAsync(epoch, token).ConfigureAwait(false); }
        if (!connectionIdentity && !local && request.Password is { } password
            && source.AdministrationPrincipalFor(epoch, request.Account, password, false) is null)
        {
            // Only this explicit trial may authenticate once. Campaigns never enter this path.
            using var candidate = await AdCredentialValidation.RunAsync(source,
                new(request.Account, CredentialRules.Remote, workstation.Name), password, AdConnectionFactory.Create, token).ConfigureAwait(false);
            source.RecordAdministration(candidate.Identity, epoch, password);
        }
        // An explicit delegated trial refreshes the target proof, even when an older proof still exists.
        var administration = source.AdministrationForCredential(epoch, request.Account, "", request.Password, connectionIdentity);
        var requireProof = local || !administration.AllowsRemote;
        var targetIdentity = source.CaptureAdministrationTarget(workstation, epoch);
        if (requireProof)
        {
            source.ForgetLocalAdministration(request.Account, workstation.Name);
            var principal = local ? null : source.AdministrationPrincipalFor(epoch, request.Account, request.Password, connectionIdentity);
            if (!local && principal is null)
                return new("Denied", "Identité et groupes du compte absents ou périmés ; validez explicitement ce compte avant un nouvel essai sur ce poste.", "AdministrationRequired", null, workstation);
            request = request with { AdministrationPrincipal = principal };
        }
        var observed = probe is not null ? await probe(request, workstation, requireProof, token).ConfigureAwait(false)
            : await new WmiMachineAccessProbe(source.Clock).ReadAsync(request, workstation, token,
                confirmComputerName: requireProof, requireLocalAdministrator: requireProof).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (source.Epoch != epoch) throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant l’essai ; résultat écarté.");
        if (requireProof && observed.Outcome == "Observed")
        {
            if (observed.AdministratorSid is not { } sid
                || !string.Equals(observed.ConfirmedComputerName, workstation.Name, StringComparison.OrdinalIgnoreCase)
                || !source.RecordLocalAdministration(workstation, request.Account, sid, epoch, request.Password, connectionIdentity, targetIdentity))
                return new("Denied", "Administration ou identité de cette cible non confirmée ; aucune collecte autorisée.", "AdministrationRequired", null, workstation);
        }
        return observed;
    }

    internal static async Task EnsureTrialTransportAsync(AdDirectorySource source, CancellationToken token)
    {
        var settings = await RemoteCollectionSettings.EffectiveAsync(source.AccountContext, token).ConfigureAwait(false);
        if (!settings.UseCim || settings.DirectMode == "winrm")
        { throw new DomeniaOperationException("machine.trialTransport", "Cet essai de compte et la validation d’un administrateur local utilisent WMI / DCOM. Ce transport est désactivé ou un choix WinRM exclusif est en vigueur ; aucun contact envoyé. Choisissez DCOM ou Automatique dans les réglages pour cet essai explicite."); }
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
