using System.Text.Json;

namespace Domenia.Core.Poste;

/// <summary>Explicit operator choices, local and non-secret. They seed from the administrator file until first saved.</summary>
public sealed record RemoteCollectionSettings(string DirectMode, bool UseCim, bool UseWinRm, bool UseRemoteRegistry,
    bool AllowRemoteArtifacts, bool UseTaskFallback, bool UsePsExecFallback, bool UseWmiProcess, bool UseWinRmScript,
    string TransientMode, string TransientMethod, int AutomaticTargetLimit)
{
    public const string PreferenceKey = "settings.remoteCollection";
    public static RemoteCollectionSettings From(PosteConfiguration configuration) => new(configuration.DirectMode,
        configuration.UseCim, configuration.Options.UseWinRm, configuration.UseRemoteRegistry,
        configuration.AllowRemoteArtifacts, configuration.UseTaskFallback, configuration.UsePsExecFallback,
        configuration.UseWmiProcess, configuration.UseWinRmScript, configuration.TransientMode,
        configuration.TransientMethod, configuration.AutomaticTargetLimit);

    public static RemoteCollectionSettings Read(JsonElement? json, PosteConfiguration configuration)
    {
        if (json is null) { return From(configuration); }
        try
        {
            var value = json.Value.Deserialize<RemoteCollectionSettings>(new JsonSerializerOptions { PropertyNameCaseInsensitive = true,
                UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow });
            return value is not null && value.Valid() ? value : From(configuration) with { AllowRemoteArtifacts = false };
        }
        catch (JsonException) { return From(configuration) with { AllowRemoteArtifacts = false }; }
    }

    public bool Valid() => (DirectMode is "auto" or "dcom" or "winrm") && (TransientMode is "manual" or "automatic")
        && (TransientMethod is "auto" or "task" or "psexec" or "wmi" or "winrm") && AutomaticTargetLimit is >= 1 and <= 100_000
        && (DirectMode != "winrm" || UseWinRm);

    public JsonElement ToJson() => JsonSerializer.SerializeToElement(this, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });

    public PosteConfiguration Apply(PosteConfiguration configuration) => configuration with
    {
        UseCim = UseCim, UseRemoteRegistry = UseRemoteRegistry, Options = configuration.Options with { UseWinRm = UseWinRm },
        AllowRemoteArtifacts = AllowRemoteArtifacts, UseTaskFallback = UseTaskFallback, UsePsExecFallback = UsePsExecFallback,
        UseWmiProcess = UseWmiProcess, UseWinRmScript = UseWinRmScript, DirectMode = DirectMode,
        TransientMode = TransientMode, TransientMethod = TransientMethod, AutomaticTargetLimit = AutomaticTargetLimit,
    };

    public static async Task<PosteConfiguration> EffectiveAsync(EngineContext? context, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var file = context?.Readers.Find<IPosteSettingsReader>() is { } reader
            ? await reader.CurrentAsync(token).ConfigureAwait(false) : PosteConfiguration.Defaults;
        return context is not null && context.Preferences.TryGet(PreferenceKey, out var json) ? Read(json, file).Apply(file) : file;
    }
}
