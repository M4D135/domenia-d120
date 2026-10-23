using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>One selection of the shared cascade, kept for one native reading. No authentication fallback.</summary>
internal sealed class AdWorkstationAccess(AdDirectorySource source, RemoteProbeCredential credential, long epoch,
    MachineAccountService? service, long generation, string? place, string? key) : IDisposable
{
    internal RemoteProbeCredential Credential { get; } = credential;
    internal PosteConfiguration Settings { get; private init; } = PosteConfiguration.Defaults;
    internal WmiWorkstationReader InventoryReader() => new(source.Clock, configuration: Settings);

    internal static async Task<AdWorkstationAccess> AcquireAsync(AdDirectorySource source, string host, CancellationToken token)
    {
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        var settings = source.AccountContext?.Readers.Find<IPosteSettingsReader>() is { } configuration
            ? await configuration.CurrentAsync(token).ConfigureAwait(false) : PosteConfiguration.Defaults;
        var service = source.AccountContext is { } context ? MachineAccountService.From(context) : null;
        using var selected = service?.CredentialFor(session, host);
        var origin = selected?.Source ?? (session.Authentication.Method == AuthenticationMethod.ExplicitCredentials ? MachineAccountSource.Connection : MachineAccountSource.Windows);
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
            selected?.AccountKey ?? CredentialRules.AccountKey(credential.Account, session.Domain?.DnsName, session.Domain?.NetbiosName, host)) { Settings = settings };
        try { result.EnsureCurrent(); return result; } catch { result.Dispose(); throw; }
    }

    internal void EnsureCurrent()
    {
        if (source.Epoch != epoch || service is not null && service.Generation != generation)
        { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié pendant la lecture ; résultat écarté."); }
    }

    internal void Refused(string host, string operation, bool authenticationRejected)
    {
        EnsureCurrent();
        if (source.AccountContext is not { } context) { return; }
        AccountAccess.From(context).RegisterRefusal(CredentialRules.Remote, operation, host,
            authenticationRejected ? "badCredentials" : "accessDenied", key, true);
        if (authenticationRejected && place is not null) { service?.RecordRefusal(place, Credential.Account, "Authentification refusée par le poste."); }
    }
    public void Dispose() => Credential.Dispose();
}
