using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource
{
    // Test-only transport factory. Selection, scope, pause, epoch and identity guards still run normally.
    // Production never sets this seam and keeps the native authenticated connection behavior.
    internal Func<RemoteProbeCredential?, IAdConnection>? ReadConnectionFactory { get; init; }

    // Test-only native identity copy for recording LDAP transports. Epoch and account checks still run,
    // and production has no fallback when its actual authenticated connection is unavailable.
    internal Func<AdCredentialCopy>? SessionCredentialCopy { get; init; }

    // Recording annuaries must opt in explicitly to an administration proof, independently of credential copying.
    internal AdministrationIdentity? AdministrationOverride { get; init; }

    // Test-only desktop SID, so identity tests do not depend on the account running them (a CI runner runs as SYSTEM).
    // Production never sets it and reads the SID of the current Windows identity.
    internal Func<string?>? DesktopSidOverride { get; init; }
}
