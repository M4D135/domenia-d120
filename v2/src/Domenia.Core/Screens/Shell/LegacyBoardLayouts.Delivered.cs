using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Core;

public static partial class LegacyBoardLayouts
{
    // D1 Test-DomeniaBoardLayoutText / Test-DomeniaBoardLegacyLayout (Boards.Model 955–993).
    // SHA-256 of the exact ordered key|group|visual|size lines, UTF-8, one LF after every line.
    // Source, title and pause are checked separately; D1 deliberately ignores the generated identifiers.
    private static readonly (string Board, int Count, string Sha256)[] DeliveredLayouts =
    [
        ("Fleet", 17, "b25a91abd7647d20823b574260df02162348f0fce4a774f53ec612a81fe78de9"), // DomeniaFleetLegacyLayoutText
        ("Fleet", 17, "e2e890cae26d5a1e2dc0655ea8ae5b7f30dd3d417cb3044a408d7e37a4617856"), // DomeniaFleetPairLayoutText
        ("Computer", 42, "4ae43a14ab5feb2a2b8d78c86940c027b5bfd93cd261c1751ee02af7e19883cc"), // DomeniaComputerLegacyLayoutText
        ("Computer", 44, "64588a891039a0db97a1d418da592a9b90cefa8f47099a83bcd1f12008744d56"), // DomeniaComputerW11LayoutText
    ];

    private static LegacyBoardProposal? DeliveredProposal(string board, string setting, string original, JsonElement rows,
        LegacyBoardConfiguration? configuration)
    {
        var signatures = DeliveredLayouts.Where(row => row.Board == board && row.Count == rows.GetArrayLength()).ToArray();
        if (signatures.Length == 0) return null;
        var text = new StringBuilder();
        foreach (var row in rows.EnumerateArray())
        {
            if (!string.Equals(Text(row, "Source", 16), "Builtin", StringComparison.OrdinalIgnoreCase)
                || !string.IsNullOrEmpty(Text(row, "Title", 80))) return null;
            var paused = Property(row, "Paused");
            if (paused is not (null or { ValueKind: JsonValueKind.Null or JsonValueKind.False })) return null;
            text.Append(Text(row, "Key", 80)).Append('|').Append(Text(row, "Group", 80)).Append('|')
                .Append(Text(row, "Visual", 32)).Append('|').Append(Text(row, "Size", 8)).Append('\n');
        }
        var digest = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString())));
        if (!signatures.Any(signature => signature.Sha256 == digest)) return null;
        // A Dashboard value was present at D1's Get-DomeniaBoardLayout boundary: Widgets.* was not selected.
        // Team conversion must not reinterpret a deliberately chosen old team layout as another delivered layout.
        var emptySettings = JsonSerializer.SerializeToElement(new Dictionary<string, string>());
        var team = configuration is null ? null : TeamProposal(emptySettings, board, configuration);
        if (team is not null)
            return team with
            {
                Setting = setting,
                OriginalLayout = team.State == "ready" ? original : null,
                Summary = team.State == "ready" ? "Ancienne disposition livrée reconnue sans personnalisation ; le défaut d’équipe sera repris. Présentations adaptées aux cartes D2 ; textes et empreintes des deux sources conservés."
                    : "Ancienne disposition livrée reconnue sans personnalisation. " + team.Summary,
            };
        var items = board == "Fleet" ? FleetCatalog.DefaultLayout() : PosteBoardLayouts.Defaults(board);
        return new(board, setting, "ready",
            "Ancienne disposition livrée reconnue sans personnalisation ; la disposition livrée actuelle sera reprise. Le texte D1 original reste conservé.",
            items.Length, items, original);
    }
}
