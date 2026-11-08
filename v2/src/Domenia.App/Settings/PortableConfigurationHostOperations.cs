using System.Text.Json;
using Domenia.Bridge;
using Domenia.App.Settings;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.App;

internal sealed class ConfigurationSeedHost
{
    private readonly EngineContext context;
    private readonly ConfigurationSeedCoordinator coordinator;
    private ConfigurationSeedView? initial;
    internal static ConfigurationSeedHost From(EngineContext context) => context.Shared(static c => new ConfigurationSeedHost(c));
    private ConfigurationSeedHost(EngineContext context)
    {
        this.context = context;
        var store = context.Preferences as IConfigurationPreferenceStore ?? throw new InvalidDataException("Magasin de configuration indisponible.");
        var enabled = context.Preferences.Persistent && !HostFacts.Unattended;
        string SourcePath() => Path.Combine(AppPaths.AppDirectory, PortableConfiguration.FileName);
        coordinator = new(context.Mode, enabled, store, ProductInfo.Version, context.Clock, token =>
        {
            var source = PortableConfigurationFile.Read(SourcePath(), token);
            return source is null ? null : new(source.Document, source.FileSha256);
        }, (source, token) => PortableConfigurationFile.Hold(SourcePath(), source.FileSha256, token), () =>
        {
            var webProfile = AppPaths.WebViewUserData(context.Mode);
            if (webProfile is null) return false;
            try { _ = File.GetAttributes(webProfile); return false; }
            catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return true; }
        });
    }
    internal async Task InitializeAsync(CancellationToken token) => initial = await SafeExamineAsync(true, token).ConfigureAwait(false);
    internal Task<ConfigurationSeedView> StatusAsync(CancellationToken token) => initial is { AutomaticallyApplied: true } applied
        ? Task.FromResult(applied) : SafeExamineAsync(false, token);
    private async Task<ConfigurationSeedView> SafeExamineAsync(bool initialize, CancellationToken token)
    {
        try { return await coordinator.ExamineAsync(initialize, token).ConfigureAwait(false); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
        {
            const string problem = "Configuration jointe non appliquée : source ou préférences illisibles, modifiées ou incompatibles. Vos choix sont conservés.";
            context.Log.Warning(problem + " (" + ex.GetType().Name + ")");
            return new(false, false, false, null, null, null, null, problem, Problem: problem);
        }
    }
    internal async Task<ConfigurationApplied> DecideAsync(string id, string sha, string fingerprint, bool apply, CancellationToken token)
    {
        var result = await coordinator.DecideAsync(id, sha, fingerprint, apply, token).ConfigureAwait(false);
        initial = null;
        return result;
    }
}

public sealed class PortableConfigurationHostOperations : IOperationModule
{
    public string Screen => "settings";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
    [
        new("settings.configuration.seed.status", OperationClass.LocalRead, (args, _, token) =>
        {
            BridgeArguments.RequireNone(args);
            return Status(context, token);
        }, "Configuration jointe au pack, proposition par identité de build et SHA ; simulation refusée avant lecture."),
        new("settings.configuration.seed.decide", OperationClass.LocalWrite, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["decisionId", "sourceSha256", "fingerprint", "apply"]);
            if (!values.TryGetValue("apply", out var apply) || apply.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                throw BridgeArguments.Invalid("Décision explicite attendue.");
            return await ConfigurationSeedHost.From(context).DecideAsync(BridgeArguments.GetString(values, "decisionId"), BridgeArguments.GetString(values, "sourceSha256"),
                BridgeArguments.GetString(values, "fingerprint"), apply.GetBoolean(), token).ConfigureAwait(false);
        }, "Accepte ou refuse explicitement cette configuration de cette version, décision atomique et source requalifiée."),
    ];
    private static async Task<object?> Status(EngineContext context, CancellationToken token) => await ConfigurationSeedHost.From(context).StatusAsync(token).ConfigureAwait(false);
}
