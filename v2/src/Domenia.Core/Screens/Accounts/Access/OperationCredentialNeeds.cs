using Domenia.Core.Poste;

namespace Domenia.Core;

[Flags]
public enum OperationCredentialChannel { None = 0, Directory = 1, Remote = 2, Laps = 4, BitLocker = 8, Authentication = 16 }

/// <summary>A capability declaration, never an identity or a copy of a credential. Providers still enforce their own
/// account selection, generation, target identity, administration and consent.</summary>
public sealed record OperationCredentialNeed(string Operation, bool Known, OperationCredentialChannel Channels)
{
    public bool ContainsSecretResource => (Channels & (OperationCredentialChannel.Laps | OperationCredentialChannel.BitLocker)) != 0;
    public void RequireDirectory(string scope) => Require(scope switch
    {
        CredentialRules.Laps => OperationCredentialChannel.Laps,
        CredentialRules.BitLocker => OperationCredentialChannel.BitLocker,
        CredentialRules.Directory => OperationCredentialChannel.Directory,
        _ when scope.StartsWith(CredentialRules.DirectoryOperationPrefix, StringComparison.Ordinal) => OperationCredentialChannel.Directory,
        _ => throw Refused(),
    });
    public void RequireRemote() => Require(OperationCredentialChannel.Remote);
    public void RequireAuthentication() => Require(OperationCredentialChannel.Authentication);
    private void Require(OperationCredentialChannel channel)
    { if (!Known || (Channels & channel) != channel) throw Refused(); }
    private static DomeniaOperationException Refused() => new("operation.credentialsDenied", "Cette opération n’autorise pas ce canal d’identifiants ; aucun secret transmis.");
}

/// <summary>Closed operations and write kinds. No prefix matching grants access. Legacy IDs are accepted only if they
/// are present in the existing closed operation catalogue. V2 remote actions explicitly read AD identity first.</summary>
public static class OperationCredentialNeeds
{
    private const OperationCredentialChannel Directory = OperationCredentialChannel.Directory;
    private const OperationCredentialChannel Remote = OperationCredentialChannel.Remote;
    public static OperationCredentialNeed ForWrite(string kind) => kind switch
    {
        PosteRemoteWrites.WakeKind => new(kind, true, Directory),
        PosteRemoteWrites.RestartKind or PosteRemoteWrites.RestartCancelKind or PosteRemoteWrites.GpUpdateKind
            or PosteRemoteWrites.ServiceKind or PosteRemoteWrites.RunKind or "poste.read.cleanup" => new(kind, true, Directory | Remote),
        _ => new(kind, false, OperationCredentialChannel.None),
    };
    public static OperationCredentialNeed ForRead(string operation, string? mode = null, string? resource = null) => operation == "poste.account.other"
        ? resource switch { "laps" => new(operation, true, OperationCredentialChannel.Authentication | OperationCredentialChannel.Laps),
            "bitlocker" => new(operation, true, OperationCredentialChannel.Authentication | OperationCredentialChannel.BitLocker), _ => new(operation, false, OperationCredentialChannel.None) }
        : operation == "search.recheck"
        ? mode switch { "ping" => new(operation, true, OperationCredentialChannel.None), null or "console" => new(operation, true, Directory | Remote), _ => new(operation, false, OperationCredentialChannel.None) }
        : For(operation);
    public static OperationCredentialNeed For(string operation)
    {
        var channels = operation switch
        {
            "poste.tool.open" or "poste.suite.launch" or "search.netdiag" or "search.netdiag.plan" or "search.dns.reverse" or "ComputerPing" or "LiveSelectedPing" or "ParkPing" or "PresenceScan"
                or "SelectedPresence" or "BatchNetworkDiag" or "DnsReverseLookup" => OperationCredentialChannel.None,
            "poste.wake.plan" or "poste.ping" => Directory,
            "poste.laps" or "poste.laps.reveal" => OperationCredentialChannel.Laps,
            "poste.bitlocker.list" or "poste.bitlocker.reveal" or "poste.secrets.index" => OperationCredentialChannel.BitLocker,
            "accounts.connection.switch" or "accounts.connection.correct" or "accounts.access.test" or "accounts.access.recover"
                or "accounts.access.tryRemote" or "accounts.access.activate" or "machine.account.trial" or "session.connect"  => OperationCredentialChannel.Authentication | Directory | Remote,
            "poste.restart.plan" or "poste.restartCancel.plan" or "poste.gpupdate.plan" or "poste.service.plan" or "poste.run.plan"
                or "poste.read.cleanup.plan" or "poste.read.pending" or "poste.inventory" or "poste.inventory.full" or "poste.software"
                or "poste.services" or "poste.events" or "poste.sessions" or "poste.restart.sessions" or "poste.quickDiag"
                or "poste.diagnostic" or "poste.wmi" or "poste.wmi.query" or "poste.wmi.schema" or "poste.probes.collect"
                or "poste.personalProbe.run" or "poste.wmi.classes" or "poste.wmi.namespaces" or "poste.processes" or "poste.slow" or "poste.live" or "poste.lastUser.detect" or "poste.performance" or "poste.storage"
                or "accueil.refresh.run" or "accueil.widget.run" or "accueil.probe" or "search.survey.run"
                or "requetes.collect.run" or "requetes.collect.object" or "requetes.wmi.run" or "requetes.wmi.classes" or "requetes.wmi.namespaces" or "requetes.wmi.relation" or "requetes.wmi.schema" or "relations.console.read"
                or "assistance.step.run" or "audit.dc.probe" or "audit.dc.services" or "audit.object.gpoApplied"
                or "audit.object.machineIdentity" or "relations.detect.collect" or "relations.detect.run" or "relations.computer.read"
                or "relations.harvest.run" or "dashboard.widget.refresh" or "operations.survey.resume" => Directory | Remote,
            "synchro.read.run" or "synchro.absences.check" or "synchro.gaps.read" or "synchro.park.shared.read" or "operations.check.run"
                or "schema.read" or "shell.lookup" or "shell.lookup.verify" or "shell.ou.resolve"
                or "sync.run" or "sync.estimate" or "sync.preview" or "directory.refresh" or "session.domain"
                or "poste.open" or "poste.groups.search" or "poste.account.plan" or "poste.group.plan" or "poste.move.plan"
                or "poste.rename.plan" or "poste.profile.plan" or "relations.subject" or "relations.search"
                or "relations.refresh" or "relations.remove.plan" or "assistance.subject.read" or "assistance.subjects.search"
                or "assistance.subjects.suggest" or "assistance.computers.resolve" or "accounts.batch.preview" or "accounts.batch.plan"
                or "accounts.batch.confirm" or "accounts.unlock.plan" or "accounts.disable.plan" or "accounts.enable.plan"
                or "assistance.pin.locate" or "search.view" or "relations.compare" or "relations.associate.plan"
                or "fiche.history" or "fiche.compare" or "audit.suggestions" or "audit.overview" or "audit.localTotals" or "audit.object.relations" or "audit.object.history"
                or "search.browse" or "search.preload" or "search.preview" or "search.compare" or "search.containers" or "search.checks.resume"
                or "fiche.createOu.plan" or "fiche.delete.plan" or "fiche.destinations" or "fiche.enable.plan" or "fiche.expiration.plan"
                or "fiche.expirePassword.plan" or "fiche.groups.delta.check" or "fiche.membership.plan" or "fiche.move.plan"
                or "fiche.options.plan" or "fiche.rawAttribute.plan" or "fiche.resetPassword.plan" or "fiche.update.plan"
                or "fiche.lifecycle.create" or "fiche.lifecycle.prepare" or "fiche.compensation.plan" or "fiche.callSheet.read" or "fiche.presence"
                or "audit.dc.list" or "audit.object.groups" or "audit.object.membership" or "audit.object.tokenGroups" or "audit.objects.search" or "audit.target"
                or "relations.targets.search" or "relations.subjects.search" or "relations.orphans.check"
                or "requetes.ldap.read" or "requetes.reference.distribution.read" or "requetes.reference.distribution.list"
                or "accounts.expiration.plan" or "accounts.password.plan" or "accounts.mustChange.plan" => Directory,
            _ => (OperationCredentialChannel?)null,
        };
        if (channels is { } selected) return new(operation, true, selected);
        var declared = OperationRequirements.ForBridge(operation);
        if (!declared.Known) return new(operation, false, OperationCredentialChannel.None);
        return new(operation, true, declared.Resource switch
        {
            "Directory" => Directory,
            "Remote" => Directory | Remote,
            "Laps" => OperationCredentialChannel.Laps,
            "BitLocker" => OperationCredentialChannel.BitLocker,
            "Network" or "Local" => OperationCredentialChannel.None,
            _ => OperationCredentialChannel.None,
        });
    }
}

/// <summary>Installed after the bridge's registry admission, or by a typed write executor. An absent scope is not an
/// authorization: direct provider callers retain the native access gates. A present unknown scope grants no channel.</summary>
public static class OperationCredentialScope
{
    private static readonly AsyncLocal<OperationCredentialNeed?> Current = new();
    public static IDisposable Enter(OperationCredentialNeed need)
    { ArgumentNullException.ThrowIfNull(need); var previous = Current.Value; Current.Value = need; return new Restore(previous); }
    public static void RequireDirectory(string scope) => Current.Value?.RequireDirectory(scope);
    public static void RequireRemote() => Current.Value?.RequireRemote();
    public static void RequireAuthentication() => Current.Value?.RequireAuthentication();
    private sealed class Restore(OperationCredentialNeed? previous) : IDisposable
    {
        private bool disposed;
        public void Dispose() { if (disposed) return; disposed = true; Current.Value = previous; }
    }
}
