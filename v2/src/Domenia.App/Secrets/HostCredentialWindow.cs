using Domenia.Core;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.App.Secrets;

public sealed class HostCredentialWindow(IDirectorySource source) : IAccountsCredentialWindow, IAccountsValidationWindow, IInitialLoginWindow, IRuntimeConfigurationConsumer
{
    private RuntimeConfiguration configuration = RuntimeConfiguration.Default;
    public void Configure(RuntimeConfiguration value) => configuration = value;
    private Task<ShellPolicy> ReadPolicyAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var policy = configuration.Shell;
        if (policy.Problem is not null) { TechnicalLog.Warning("Politique du login non lue : " + policy.Problem); }
        foreach (var entry in policy.GuiPolicy.Where(e => !e.Valid || !GuiElementPolicies.IsKnownElement(e.Element)))
        { TechnicalLog.Warning("GuiElementPolicy : " + entry.Element + " — " + (!entry.Valid ? entry.Text : "Contrôle sans correspondance dans cette interface ; ignoré.")); }
        return Task.FromResult(policy);
    }
    public async Task<CredentialWindowEntry?> AskAsync(CredentialWindowRequest request, CancellationToken cancellationToken)
    {
        var policy = await ReadPolicyAsync(cancellationToken).ConfigureAwait(false);
        return await NativeSecretDialog.ShowAsync(() => new CredentialWindow(request, new WindowsCredentialVault(source), policy, configuration.Accounts.SecretRevealSeconds),
            static form => form.TakeEntry(), cancellationToken).ConfigureAwait(false);
    }
    public async Task<T> RunAsync<T>(LoginAppearance appearance, Func<CancellationToken, Task<T>> validate, CancellationToken token)
    {
        if (source.Kind == DirectorySourceKind.Simulation) return await validate(token).ConfigureAwait(false);
        var policy = await ReadPolicyAsync(token).ConfigureAwait(false);
        return await NativeValidationDialog.RunAsync(appearance, policy, validate, token).ConfigureAwait(false);
    }
    public async Task<InitialLoginChoice> ChooseAsync(LoginAppearance appearance, string? feedback, string? rememberedLogin, CancellationToken token)
    {
        var policy = await ReadPolicyAsync(token).ConfigureAwait(false);
        return await NativeInitialLoginDialog.ShowAsync(appearance, policy, feedback, rememberedLogin, token,
            source is IWindowsSessionChoiceSource windows ? windows.WindowsSessionChoice : WindowsSessionChoice.Read(false, source.Kind == DirectorySourceKind.Simulation, null, "", Environment.MachineName)).ConfigureAwait(false);
    }
}
