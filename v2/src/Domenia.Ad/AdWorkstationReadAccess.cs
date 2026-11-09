using Domenia.Core;

namespace Domenia.Ad;

/// <summary>One LDAP selection and one machine selection for the same logical read. The single one-shot is
/// consumed first, so retiring its slot does not invalidate the companion lease. Two one-shots from the shared
/// AccountAccess store still refuse before native contact; no generation is rebased or credential selected again.</summary>
internal sealed class AdWorkstationReadAccess(AdReadAccess directory, AdWorkstationAccess machine) : IDisposable
{
    internal AdReadAccess Directory { get; } = directory;
    internal AdWorkstationAccess Machine { get; } = machine;
    internal bool SingleUse { get; private init; }

    internal static async Task<AdWorkstationReadAccess> AcquireAsync(AdDirectorySource source, string host, string? directoryTarget,
        CancellationToken token, long? expectedAccountVersion = null, long? expectedMachineGeneration = null)
    {
        var epoch = source.Epoch;
        var accounts = source.AccountContext is { } context ? AccountAccess.From(context) : null;
        var preview = accounts is null ? default : await accounts.PreviewDirectoryReadAsync(CredentialRules.Directory, directoryTarget, token).ConfigureAwait(false);
        var machinePreview = await AdWorkstationAccess.PreviewAsync(source, host, token).ConfigureAwait(false);
        if (source.Epoch != epoch || accounts is not null && accounts.SelectionVersion != preview.SelectionVersion)
        { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié depuis l’aperçu d’admission ; aucun envoi."); }
        if (expectedAccountVersion is { } expectedAccount && preview.SelectionVersion != expectedAccount
            || expectedMachineGeneration is { } expectedMachine && (machinePreview.Generation ?? 0) != expectedMachine)
        { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte différent de la sélection confirmée ; aucune admission."); }
        AdReadAccess? ldap = null;
        AdWorkstationAccess? selected = null;
        try
        {
            if (preview.OneShot)
            {
                ldap = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, directoryTarget, token,
                    expectedSelectionVersion: preview.SelectionVersion).ConfigureAwait(false);
                // This exact one-shot retirement advances AccountAccess once, and its already-initialized
                // machine mirror once. Anything else is a concurrent change, never a new authorization.
                if (accounts?.SelectionVersion != checked(preview.SelectionVersion + 1))
                { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Sélection modifiée pendant l’admission LDAP ; aucun contact machine."); }
                ldap.EnsureCurrent();
                selected = await AdWorkstationAccess.AcquireAsync(source, host, token,
                    machinePreview.Generation is { } version ? checked(version + 1) : null, machinePreview, readOnly: true).ConfigureAwait(false);
            }
            else
            {
                selected = await AdWorkstationAccess.AcquireAsync(source, host, token, machinePreview.Generation, machinePreview, readOnly: true).ConfigureAwait(false);
                var expected = accounts?.SelectionVersion;
                selected.EnsureCurrent();
                ldap = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, directoryTarget, token,
                    expectedSelectionVersion: expected).ConfigureAwait(false);
            }
            token.ThrowIfCancellationRequested();
            ldap.EnsureCurrent();
            await selected.BeforeContactAsync(source, host, token).ConfigureAwait(false);
            ldap.EnsureCurrent();
            return new(ldap, selected) { SingleUse = preview.OneShot || selected.SingleUse };
        }
        catch { selected?.Dispose(); ldap?.Dispose(); throw; }
    }

    public void Dispose() { Machine.Dispose(); Directory.Dispose(); }
}
