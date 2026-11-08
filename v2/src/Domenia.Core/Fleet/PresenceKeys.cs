using System.Collections.Immutable;
using Domenia.Core.Poste;

namespace Domenia.Core;

/// <summary>
/// The six presence keys of Domenia 1 (Get-DomeniaPresenceStateKeys), in display order. A key carries the meaning; a label,
/// a colour or an icon may change without changing it. « None » is nothing to report at all (the target is not a workstation,
/// or its presence was never asked); « Unknown » is a test that gave no verdict.
/// </summary>
public enum PresenceKey
{
    Online,
    NoReply,
    Error,
    Pending,
    Unknown,
    None,
}

/// <summary>
/// The one vocabulary of the presence keys read by colours, pills, filters and counters (TRV-112). The pages keep their own
/// state enums but reach the same keys through this class, and <see cref="FromStored"/> converts the labels stored by
/// Domenia 1 and by the older pages (ConvertTo-DomeniaPresenceStateKey). Pure.
/// </summary>
public static class PresenceKeys
{
    /// <summary>The six keys, in display order.</summary>
    public static ImmutableArray<PresenceKey> All { get; } = [PresenceKey.Online, PresenceKey.NoReply, PresenceKey.Error, PresenceKey.Pending, PresenceKey.Unknown, PresenceKey.None];

    /// <summary>Folded marks of a value taken from the local memory, which never states a current verdict.</summary>
    private static readonly ImmutableArray<string> MemoryMarks = ["memoire", "remembered"];

    /// <summary>Stable token of a key, as the console and the saved filters write it: « online », « noReply », « none ».</summary>
    public static string Key(PresenceKey key) => key switch
    {
        PresenceKey.Online => "online",
        PresenceKey.NoReply => "noReply",
        PresenceKey.Error => "error",
        PresenceKey.Pending => "pending",
        PresenceKey.Unknown => "unknown",
        _ => "none",
    };

    /// <summary>A key token, whatever the case, the accents and the separators written; false for anything else, including an empty text.</summary>
    public static bool TryKey(string? text, out PresenceKey key)
    {
        var folded = Fold(text);
        foreach (var candidate in All)
        {
            if (folded.Length != 0 && string.Equals(folded, Key(candidate), StringComparison.OrdinalIgnoreCase))
            {
                key = candidate;
                return true;
            }
        }
        key = PresenceKey.None;
        return false;
    }

    /// <summary>Label of a key, as the pills and the filters show it. Never the key: a label may change without changing the sense.</summary>
    public static string Label(PresenceKey key) => key switch
    {
        PresenceKey.Online => "En ligne",
        PresenceKey.NoReply => "Sans réponse au ping",
        PresenceKey.Error => "Erreur de ping",
        PresenceKey.Pending => "Test en attente",
        PresenceKey.Unknown => "Non vérifié",
        _ => "Aucune présence à rendre",
    };

    /// <summary>
    /// Key of a label stored by Domenia 1 or by an older page (presence of the dashboard, of a base or of an import): the
    /// French labels, the keys themselves and their synonyms, whatever the case and the accents. A text with nothing to read
    /// is « None », a remembered value keeps the verdict it carries and never invents one.
    /// </summary>
    public static PresenceKey FromStored(string? stored)
    {
        var folded = Fold(stored);
        if (folded.Length == 0)
        {
            return PresenceKey.None;
        }
        if (IsRemembered(folded))
        {
            folded = WithoutMemoryMark(folded);
            if (folded.Length == 0)
            {
                return PresenceKey.Unknown;
            }
        }
        return folded switch
        {
            "en ligne" or "online" or "repond au ping" or "reponse recue" or "reply" or "connecte" => PresenceKey.Online,
            "sans reponse" or "sans reponse au ping" or "ne repond pas au ping" or "pas de reponse" or "offline" or "noreply" or "no reply" => PresenceKey.NoReply,
            "erreur" or "erreur de ping" or "erreur de test" or "error" or "echec" or "sonde en echec" => PresenceKey.Error,
            "en attente" or "test en attente" or "en cours" or "pending" or "a venir" => PresenceKey.Pending,
            "inconnu" or "unknown" or "non verifie" or "presence non verifiee" or "presence non confirmee" or "unchecked" or "non teste" => PresenceKey.Unknown,
            "aucun" or "aucune presence" or "none" or "non applicable" or "na" or "n/a" or "—" => PresenceKey.None,
            _ => PresenceKey.Unknown,
        };
    }

    /// <summary>True when the stored text says the value comes from the local memory rather than from a test of now.</summary>
    public static bool IsRemembered(string? stored) => HasMemoryMark(Fold(stored));

    private static bool HasMemoryMark(string folded) => MemoryMarks.Any(mark => folded.Contains(mark, StringComparison.Ordinal));

    /// <summary>Key of the badge of the header: no ICMP answer is « NoReply », never a proof of a shut machine; a remembered value states no current verdict.</summary>
    public static PresenceKey FromBadge(PresenceState state) => state switch
    {
        PresenceState.Online => PresenceKey.Online,
        PresenceState.Offline => PresenceKey.NoReply,
        PresenceState.Pending => PresenceKey.Pending,
        PresenceState.Error => PresenceKey.Error,
        _ => PresenceKey.Unknown,
    };

    /// <summary>Badge state of a key; the pill shows a remembered value with its own state, not this one.</summary>
    public static PresenceState ToBadge(PresenceKey key) => key switch
    {
        PresenceKey.Online => PresenceState.Online,
        PresenceKey.NoReply => PresenceState.Offline,
        PresenceKey.Pending => PresenceState.Pending,
        PresenceKey.Error => PresenceState.Error,
        _ => PresenceState.Unknown,
    };

    public static PresenceKey FromSearch(SearchPresenceState state) => state switch
    {
        SearchPresenceState.Online => PresenceKey.Online,
        SearchPresenceState.NoReply => PresenceKey.NoReply,
        SearchPresenceState.Error => PresenceKey.Error,
        _ => PresenceKey.Unknown,
    };

    public static SearchPresenceState ToSearch(PresenceKey key) => key switch
    {
        PresenceKey.Online => SearchPresenceState.Online,
        PresenceKey.NoReply => SearchPresenceState.NoReply,
        PresenceKey.Error => SearchPresenceState.Error,
        _ => SearchPresenceState.Unknown,
    };

    /// <summary>Bucket of the query grid, which keeps its three filters (« online », « offline », « unchecked »).</summary>
    public static string GridKey(PresenceKey key) => key switch
    {
        PresenceKey.Online => "online",
        PresenceKey.NoReply => "offline",
        _ => "unchecked",
    };

    /// <summary>The stored text freed of the memory mark, kept or parenthesized: « répond au ping (mémoire locale) » still carries its verdict.</summary>
    private static string WithoutMemoryMark(string folded) => string.Concat(folded.Split('(', StringSplitOptions.RemoveEmptyEntries)
        .Select(part => HasMemoryMark(part) ? "" : part))
        .Replace(")", "", StringComparison.Ordinal).Trim(' ', ':', ';', ',');

    private static string Fold(string? text) => string.IsNullOrWhiteSpace(text)
        ? ""
        : FrenchText.Fold(text.Replace(FrenchText.Nbsp, " ", StringComparison.Ordinal).Replace("_", "", StringComparison.Ordinal).Replace("-", "", StringComparison.Ordinal).Trim());
}
