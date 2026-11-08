using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

public sealed class ConfigurationOperations : IOperationModule
{
    public string Screen => "settings";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        IConfigurationPreferenceStore Store() => context.Preferences as IConfigurationPreferenceStore ?? throw new InvalidDataException("Import atomique indisponible pour ce magasin.");
        return
        [
            new("settings.configuration.options", OperationClass.LocalRead, async (args, _, token) =>
            {
                BridgeArguments.RequireNone(args);
                var snapshot = await Store().ReadConfigurationAsync(token).ConfigureAwait(false);
                var values = PortableConfiguration.WithDefaults(snapshot.Values);
                return new { simulated = context.Mode == AppMode.Simulation, fileName = PortableConfiguration.FileName, fingerprint = snapshot.Fingerprint,
                    choices = values.Where(v => PreferenceApproval.IsApproved(v.Key)).OrderBy(v => v.Key, StringComparer.Ordinal).Select(v =>
                    {
                        var valid = true;
                        try { PortableConfiguration.ValidateValue(v.Key, v.Value); }
                        catch (Exception ex) when (ex is InvalidDataException or JsonException) { valid = false; }
                        return new { key = v.Key, label = PreferenceApproval.Approved.First(a => a.Key == v.Key || a.Key.EndsWith('.') && v.Key.StartsWith(a.Key, StringComparison.Ordinal)).Label,
                            value = v.Value, valid, selected = valid && !v.Key.StartsWith(WorkingScope.PreferencePrefix, StringComparison.Ordinal) };
                    }).ToArray(), excluded = values.Keys.Where(k => !PreferenceApproval.IsApproved(k)).Order(StringComparer.Ordinal).ToArray() };
            }, "Choix portables approuvés, valeurs effectives par défaut et exclusions explicites ; aucune acquisition réseau."),
            new("settings.configuration.export", OperationClass.LocalRead, async (args, _, token) =>
            {
                var fields = BridgeArguments.ReadObject(args, ["keys", "interface", "fingerprint"]);
                if (!fields.TryGetValue("keys", out var raw) || raw.ValueKind != JsonValueKind.Array || raw.GetArrayLength() > PreferenceTransfer.MaxKeys
                    || raw.EnumerateArray().Any(v => v.ValueKind != JsonValueKind.String)) throw BridgeArguments.Invalid("Sélection de clés attendue.");
                var current = await Store().ReadConfigurationAsync(token).ConfigureAwait(false);
                if (current.Fingerprint != BridgeArguments.GetString(fields, "fingerprint")) throw new InvalidDataException("Préférences modifiées depuis la sélection ; relisez les choix.");
                return PortableConfiguration.Export(current.Values, raw.EnumerateArray().Select(v => v.GetString()!).ToArray(),
                    fields.TryGetValue("interface", out var ui) && ui.ValueKind != JsonValueKind.Null ? ui : null,
                    context.Mode == AppMode.Simulation ? "Démonstration fictive" : "Annuaire", context.Clock.GetUtcNow());
            }, "Prépare exactement la sélection confirmable, y compris l’OU si cochée ; texte validé sans identité ni secret."),
            new("settings.configuration.save", OperationClass.LocalWrite, async (args, _, token) =>
            {
                var fields = BridgeArguments.ReadObject(args, ["text"]);
                var document = PortableConfiguration.Read(BridgeArguments.GetString(fields, "text"));
                var name = context.Mode == AppMode.Simulation && context.Decision.Reason != ModeReason.Demonstration
                    ? "DEMONSTRATION-" + PortableConfiguration.FileName : PortableConfiguration.FileName;
                var saved = await context.Documents.SaveFileAsync(name, Encoding.UTF8.GetBytes(document.Text), token).ConfigureAwait(false);
                return new { saved = saved.Saved, fileName = saved.Name, sha256 = document.Sha256,
                    message = saved.Saved ? "Configuration exportée : " + saved.Name + "." : "Configuration préparée en mémoire ; aucun fichier écrit." };
            }, "Écrit le fichier de configuration validé dans les exports privés, jamais par-dessus un fichier existant."),
            new("settings.configuration.preview", OperationClass.LocalRead, async (args, _, token) =>
            {
                var fields = BridgeArguments.ReadObject(args, ["text"]);
                var document = PortableConfiguration.Read(BridgeArguments.GetString(fields, "text"));
                var current = await Store().ReadConfigurationAsync(token).ConfigureAwait(false);
                var preview = PreferenceTransfer.Preview(document.Text, key => current.Values.TryGetValue(key, out var value) ? value : null);
                return new { fingerprint = current.Fingerprint, document.Sha256, preview.Changes, preview.Unchanged,
                    @interface = document.Interface, simulated = context.Mode == AppMode.Simulation,
                    summary = "Seules les clés présentes remplacent leurs valeurs. Les autres choix, identités et données restent conservés. Une sauvegarde précède le remplacement du document existant." };
            }, "Aperçu du remplacement local avec empreinte du document courant, sans modification."),
            new("settings.configuration.apply", OperationClass.LocalWrite, async (args, _, token) =>
            {
                var fields = BridgeArguments.ReadObject(args, ["text", "fingerprint"]);
                var document = PortableConfiguration.Read(BridgeArguments.GetString(fields, "text"));
                return await Store().CommitConfigurationAsync(new(document, BridgeArguments.GetString(fields, "fingerprint"), context.Clock.GetUtcNow()), token).ConfigureAwait(false);
            }, "Import manuel atomique après aperçu : sauvegarde originale, choix concurrent protégé, aucune lecture AD/SMB déclenchée."),
            new("settings.configuration.interface", OperationClass.LocalRead, async (args, _, token) =>
            {
                BridgeArguments.RequireNone(args);
                var current = await Store().ReadConfigurationAsync(token).ConfigureAwait(false);
                return current.Values.TryGetValue(ConfigurationChanges.InterfaceKey, out var ui) ? ui : (object?)null;
            }, "Choix d’interface explicitement importé, identifié pour être appliqué une seule fois par profil web."),
        ];
    }
}
