namespace Domenia.Core;

public sealed record ConfigurationSeed(PortableConfigurationDocument Document, string FileSha256);
public sealed record ConfigurationSeedView(bool Available, bool NeedsDecision, bool AutomaticallyApplied, string? DecisionId,
    string? SourceSha256, string? Fingerprint, PortableConfigurationDocument? Document, string Message, ConfigurationApplied? Application = null, string? Problem = null);

/// <summary>No implicit source acquisition in simulation; absent profiles alone auto-apply. Existing profiles always require a decision.</summary>
public sealed class ConfigurationSeedCoordinator(AppMode mode, bool enabled, IConfigurationPreferenceStore store, string build, TimeProvider clock,
    Func<CancellationToken, ConfigurationSeed?> acquire, Func<ConfigurationSeed, CancellationToken, IDisposable> hold, Func<bool>? hasNoExistingInterface = null)
{
    public async Task<ConfigurationSeedView> ExamineAsync(bool initialize, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (mode == AppMode.Simulation || !enabled) return new(false, false, false, null, null, null, null, "Aucun fichier de configuration livré lu dans cette session.");
        var seed = acquire(token);
        if (seed is null) return new(false, false, false, null, null, null, null, "Aucune configuration par défaut jointe au pack.");
        var state = await store.ReadConfigurationAsync(token).ConfigureAwait(false);
        var id = ConfigurationChanges.DecisionId(build, seed.FileSha256);
        if (ConfigurationChanges.Decided(state.Values, id)) return new(true, false, false, id, seed.FileSha256, state.Fingerprint, null, "Une décision a déjà été enregistrée pour cette version et ce fichier. L’import manuel reste disponible.");
        if (initialize && !state.Exists && (hasNoExistingInterface?.Invoke() ?? true))
        {
            var result = await store.CommitConfigurationAsync(new(seed.Document, state.Fingerprint, clock.GetUtcNow(),
                new(id, build, seed.FileSha256, "applied"), OnlyIfAbsent: true), token, ct => hold(seed, ct)).ConfigureAwait(false);
            return new(true, false, true, id, seed.FileSha256, null, seed.Document, "Configuration livrée appliquée au profil vierge.", result);
        }
        return new(true, true, false, id, seed.FileSha256, state.Fingerprint, seed.Document,
            "Ce pack propose une configuration par défaut. Examinez les changements avant de remplacer les clés présentes dans le fichier ; les autres choix restent conservés.");
    }

    public async Task<ConfigurationApplied> DecideAsync(string id, string sourceSha, string fingerprint, bool apply, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (mode == AppMode.Simulation || !enabled) throw new InvalidDataException("Aucune configuration réelle accessible dans cette session.");
        var seed = acquire(token) ?? throw new InvalidDataException("Configuration livrée absente.");
        if (seed.FileSha256 != sourceSha || ConfigurationChanges.DecisionId(build, sourceSha) != id)
            throw new InvalidDataException("Configuration livrée remplacée ; relisez son aperçu.");
        return await store.CommitConfigurationAsync(new(apply ? seed.Document : null, fingerprint, clock.GetUtcNow(),
            new(id, build, sourceSha, apply ? "applied" : "declined")), token, ct => hold(seed, ct)).ConfigureAwait(false);
    }
}
