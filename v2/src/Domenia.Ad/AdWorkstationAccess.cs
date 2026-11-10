using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

internal sealed record AdWorkstationAdmission(long Epoch, long? Generation, MachineAccountSource? Source, string? Account, PosteConfiguration Settings);

/// <summary>One selection of the shared cascade, kept for one native reading. No authentication fallback.</summary>
internal sealed class AdWorkstationAccess(AdDirectorySource source, RemoteProbeCredential credential, long epoch,
    MachineAccountService? service, long generation, string? place, string key, string target) : IDisposable
{
    private bool disposed;
    internal RemoteProbeCredential Credential { get; } = credential;
    internal string SharingGeneration => epoch + ":" + generation + ":" + Credential.Session + ":" + key;
    internal PosteConfiguration Settings { get; private init; } = PosteConfiguration.Defaults;
    internal bool SingleUse { get; private init; }
    private bool UsesConnectionIdentity { get; init; }
    private bool TriedByWorkstation { get; init; }

    // David, 10/11/2026: the workstation grants or refuses reads with the selected identity, including typed accounts.
    // Credential selection, secret availability, pause and generation checks still apply; writes keep admission checks.
    internal WmiWorkstationReader InventoryReader() => new(source.Clock, configuration: Settings) { ProjectionReused = () => { if (source.AccountContext is { } context) { OperationActivity.From(context).RecordGroupedCimReuse(); } } };

    internal static async Task RequireNetworkIdentityAsync(AdDirectorySource source, string host, CancellationToken token, bool readOnly = false)
    {
        var preview = await PreviewAsync(source, host, token).ConfigureAwait(false);
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        if (session.Epoch != preview.Epoch) throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée avant l’admission distante ; aucun envoi.");
        var service = source.AccountContext is { } context ? MachineAccountService.From(context) : null;
        using var selected = service?.InspectCredentialFor(session, host, preview.Generation, preview.Source, preview.Account);
        var origin = selected?.Source ?? (session.Authentication.Method == AuthenticationMethod.ExplicitCredentials ? MachineAccountSource.Connection : MachineAccountSource.Windows);
        if (!readOnly)
            source.RequireAdministration(preview.Epoch, selected?.Account ?? session.Account.Login, host, selected?.Password,
                origin is MachineAccountSource.Windows or MachineAccountSource.Connection);
        token.ThrowIfCancellationRequested();
        if (source.Epoch != preview.Epoch || selected is not null && service!.Generation != selected.Generation)
            throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié pendant l’admission distante ; aucun envoi.");
    }

    internal static async Task<AdWorkstationAdmission> PreviewAsync(AdDirectorySource source, string host, CancellationToken token)
    {
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        var settings = await RemoteCollectionSettings.EffectiveAsync(source.AccountContext, token).ConfigureAwait(false);
        var state = source.AccountContext is { } context ? MachineAccountService.From(context).Build(session, host, null) : null;
        return new(session.Epoch, state?.Generation, state?.InUse.Source, state?.InUse.Account, settings);
    }

    internal static async Task<AdWorkstationAccess> AcquireAsync(AdDirectorySource source, string host, CancellationToken token,
        long? expectedGeneration = null, AdWorkstationAdmission? preview = null, bool readOnly = false)
    {
        OperationCredentialScope.RequireRemote();
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        var settings = await RemoteCollectionSettings.EffectiveAsync(source.AccountContext, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (preview is not null && (session.Epoch != preview.Epoch || !SameTransports(preview.Settings, settings)))
        { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session ou transports modifiés depuis l’aperçu ; aucun envoi."); }
        var service = source.AccountContext is { } context ? MachineAccountService.From(context) : null;
        using var selected = service?.CredentialFor(session, host, expectedGeneration: expectedGeneration,
            expectedSource: preview?.Source, expectedAccount: preview?.Account);
        var origin = selected?.Source ?? (session.Authentication.Method == AuthenticationMethod.ExplicitCredentials ? MachineAccountSource.Connection : MachineAccountSource.Windows);
        var connectionIdentity = origin is MachineAccountSource.Windows or MachineAccountSource.Connection;
        var triedByWorkstation = readOnly;
        if (!triedByWorkstation) source.RequireAdministration(session.Epoch, selected?.Account ?? session.Account.Login, host, selected?.Password, connectionIdentity);
        RemoteProbeCredential credential;
        if (origin is MachineAccountSource.Windows or MachineAccountSource.Connection)
        {
            using var connection = source.CopySessionCredential(session.Epoch, session.Account.Login);
            if (origin == MachineAccountSource.Connection && connection.Password is null)
            { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Secret du compte de connexion absent ; aucun repli Windows."); }
            var login = connection.User is null ? session.Account.Login : string.IsNullOrEmpty(connection.Domain) ? connection.User : connection.Domain + "\\" + connection.User;
            credential = new(login, connection.Password?.Copy(), origin == MachineAccountSource.Windows);
        }
        else
        {
            if (selected?.Password is null) { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Secret du compte choisi absent ; aucun autre compte essayé."); }
            var check = CredentialRules.CheckContext(CredentialRules.Remote, selected.Account, host,
                new[] { session.Domain?.DnsName, session.Domain?.NetbiosName }.OfType<string>().ToArray());
            if (!check.Valid) { throw new DomeniaOperationException(AccountAccess.ContextRefused, check.Reason); }
            credential = new(selected.Account, selected.Password.Copy(), false);
        }
        var result = new AdWorkstationAccess(source, credential, session.Epoch, service, selected?.Generation ?? 0, selected?.Place,
            selected?.AccountKey ?? CredentialRules.AccountKey(credential.Account, session.Domain?.DnsName, session.Domain?.NetbiosName, host), host)
            { Settings = settings, SingleUse = selected?.SingleUse == true, UsesConnectionIdentity = connectionIdentity, TriedByWorkstation = triedByWorkstation };
        try { result.EnsureCurrent(); return result; } catch { result.Dispose(); throw; }
    }

    internal void EnsureCurrent()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (source.Epoch != epoch || service is not null && service.Generation != generation)
        { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié pendant la lecture ; résultat écarté."); }
    }

    internal async Task BeforeContactAsync(AdDirectorySource owner, string host, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        EnsureCurrent();
        if (!ReferenceEquals(owner, source) || !string.Equals(host, target, StringComparison.OrdinalIgnoreCase))
        { throw new DomeniaOperationException(AccountAccess.ContextRefused, "Accès distant détenu pour une autre source ou cible ; aucun envoi."); }
        if (!TriedByWorkstation) source.RequireAdministration(epoch, Credential.Account, host, Credential.Password, UsesConnectionIdentity);
        service?.BeforeContact(generation, place, key);
        var current = await RemoteCollectionSettings.EffectiveAsync(source.AccountContext, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested(); EnsureCurrent(); service?.BeforeContact(generation, place, key);
        if (!SameTransports(current, Settings))
        { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Réglages CIM, registre ou transport modifiés avant la lecture ; aucun nouvel envoi."); }
    }

    private static bool SameTransports(PosteConfiguration first, PosteConfiguration second) => first.UseCim == second.UseCim
        && first.UseRemoteRegistry == second.UseRemoteRegistry && first.Options.UseWinRm == second.Options.UseWinRm
        && RemoteCollectionSettings.From(first) == RemoteCollectionSettings.From(second);

    internal void Inspect(string host, string operation, IEnumerable<SourceAccess> results)
    {
        var evidence = AccessResultInspection.Inspect(results.Select(result => new AccessResultStatus(result.Status == SourceStatus.Refused, result.AuthenticationRejected)));
        if (evidence.Refused) Refused(host, operation, evidence.AuthenticationRejected);
    }
    internal void Refused(string host, string operation, bool authenticationRejected)
    {
        EnsureCurrent();
        if (source.AccountContext is not { } context) { return; }
        AccountAccess.From(context).RegisterRefusal(CredentialRules.Remote, operation, host,
            authenticationRejected ? "badCredentials" : "accessDenied", key, true);
        if (authenticationRejected && place is not null) { service?.RecordRefusal(place, Credential.Account, "Authentification refusée par le poste."); }
    }
    public void Dispose() { if (!disposed) { disposed = true; Credential.Dispose(); } }
}
