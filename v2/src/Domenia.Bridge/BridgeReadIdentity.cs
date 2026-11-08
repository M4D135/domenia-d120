using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Only local identity observations. Never an AD precommit check, LDAP query, selection handle or credential lease.</summary>
internal static class BridgeReadIdentity
{
    internal static bool Required(string name) => name is "fiche.lockouts" or "fiche.logonByDc" or "poste.logonByDc" or "search.revalidate" or "relations.targets.search";
    internal static OperationDefinition Bind(EngineContext context, OperationDefinition definition)
        => definition.ShareRead && Required(definition.Name) ? definition with { CaptureReadIdentity = (args, token) => Capture(context, definition.Name, args, token) } : definition;

    internal static async Task<string?> Capture(EngineContext context, string operation, JsonElement arguments, CancellationToken token)
    {
        if (operation == "search.revalidate")
        {
            var values = BridgeArguments.ReadObject(arguments, ["ids"]);
            if (!values.TryGetValue("ids", out var list) || list.ValueKind != JsonValueKind.Array || list.GetArrayLength() is < 1 or > 500)
            { throw BridgeArguments.Invalid("La relecture demande de 1 à 500 GUID, sans référence opaque."); }
            var identities = new List<string>();
            foreach (var item in list.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String || !Guid.TryParse(item.GetString(), out var guid) || guid == Guid.Empty)
                { throw BridgeArguments.Invalid("Identité GUID invalide dans la sélection à relire."); }
                identities.Add(guid.ToString("D"));
            }
            token.ThrowIfCancellationRequested();
            // AdSearchReader.RereadAsync targets these immutable GUIDs directly, including a formerly known object now absent.
            return Hash(JsonSerializer.Serialize(identities));
        }
        var allowed = operation == "fiche.lockouts" ? new[] { "dn", "hours" } : operation == "relations.targets.search" ? ["dn", "text"] : ["dn"];
        var fields = BridgeArguments.ReadObject(arguments, allowed);
        var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(fields, "dn"), "dn");
        var index = await context.Readers.Require<IFicheReader>().IndexAsync([dn], token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        var matches = index.Values.Where(v => DistinguishedName.AreEqual(v.Dn, dn)).ToArray();
        if (matches.Length != 1 || matches[0].ObjectGuid == Guid.Empty) { return null; }
        var target = matches[0];
        if (operation == "fiche.lockouts" && (target.Kind != FicheKind.User || target.Sid is not { Length: > 0 and <= 256 })) { return null; }
        if (operation == "poste.logonByDc" && target.Kind != FicheKind.Computer) { return null; }
        if ((operation is "fiche.logonByDc" or "relations.targets.search") && target.Kind is not (FicheKind.User or FicheKind.Computer)) { return null; }
        if ((target.Sid?.Length ?? 0) > 256) { return null; }
        var selection = SelectionIdentity.Capture(await context.Directory.GetSessionAsync(token).ConfigureAwait(false), target.ObjectGuid,
            target.Kind.ToString().ToLowerInvariant(), target.Dn, target.Name, target.Sam, target.Sid);
        return selection is null ? null : Hash(JsonSerializer.Serialize(selection));
    }

    internal static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
