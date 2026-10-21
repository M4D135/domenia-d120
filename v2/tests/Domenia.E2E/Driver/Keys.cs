using System.Collections.Frozen;

namespace Domenia.E2E.Driver;

/// <summary>One physical key as Input.dispatchKeyEvent expects it.</summary>
internal sealed record KeyDefinition(string Key, string Code, int VirtualKey, string? Text);

/// <summary>A key with its modifiers: « Enter », « Escape », « Control+K », « Shift+Tab », « Alt+1 ».</summary>
internal sealed record KeyChord(KeyDefinition Key, IReadOnlyList<KeyDefinition> Modifiers, int ModifierMask)
{
    public string Label => string.Join("+", Modifiers.Select(m => m.Key).Append(Key.Key == " " ? "Space" : Key.Key));
}

/// <summary>Key names admitted by the « press » step (docs/E2E.md § 4).</summary>
internal static class Keys
{
    // Modifier bits of the DevTools protocol.
    private const int Alt = 1;
    private const int Control = 2;
    private const int Meta = 4;
    private const int Shift = 8;

    private static readonly FrozenDictionary<string, (KeyDefinition Key, int Bit)> ModifierKeys = new Dictionary<string, (KeyDefinition, int)>(StringComparer.OrdinalIgnoreCase)
    {
        ["Control"] = (new KeyDefinition("Control", "ControlLeft", 17, null), Control),
        ["Ctrl"] = (new KeyDefinition("Control", "ControlLeft", 17, null), Control),
        ["Shift"] = (new KeyDefinition("Shift", "ShiftLeft", 16, null), Shift),
        ["Alt"] = (new KeyDefinition("Alt", "AltLeft", 18, null), Alt),
        ["Meta"] = (new KeyDefinition("Meta", "MetaLeft", 91, null), Meta),
    }.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase);

    private static readonly FrozenDictionary<string, KeyDefinition> NamedKeys = BuildNamedKeys();

    /// <summary>Parses « Control+Shift+K »; null with a French reason when the name is not admitted.</summary>
    public static KeyChord? Parse(string? text, out string? error)
    {
        error = null;
        if (string.IsNullOrWhiteSpace(text) || text.Length > 40)
        {
            error = "touche absente ou trop longue";
            return null;
        }
        var parts = text.Split('+');
        // « Control++ » is not supported: the plus key is « Plus ».
        if (parts.Any(string.IsNullOrWhiteSpace))
        {
            error = $"touche « {text} » mal formée (écrire par exemple Control+K)";
            return null;
        }
        var modifiers = new List<KeyDefinition>();
        var mask = 0;
        foreach (var part in parts[..^1])
        {
            if (!ModifierKeys.TryGetValue(part.Trim(), out var modifier))
            {
                error = $"modificateur « {part} » inconnu (Control, Shift, Alt, Meta)";
                return null;
            }
            if ((mask & modifier.Bit) != 0)
            {
                error = $"modificateur « {part} » répété";
                return null;
            }
            modifiers.Add(modifier.Key);
            mask |= modifier.Bit;
        }
        var name = parts[^1].Trim();
        var key = Resolve(name, (mask & Shift) != 0);
        if (key is null)
        {
            error = $"touche « {name} » inconnue (lettres, chiffres, Enter, Escape, Tab, Space, flèches, F1 à F12…)";
            return null;
        }
        // With Control, Alt or Meta a printable key types nothing (shortcut), as on a real keyboard.
        if ((mask & (Control | Alt | Meta)) != 0 && key.Text is not null && key.Code != "Enter")
        {
            key = key with { Text = null };
        }
        return new KeyChord(key, modifiers, mask);
    }

    private static KeyDefinition? Resolve(string name, bool shift)
    {
        if (NamedKeys.TryGetValue(name, out var named))
        {
            return named;
        }
        if (name.Length == 1)
        {
            var c = name[0];
            if (c is >= 'a' and <= 'z' or >= 'A' and <= 'Z')
            {
                var lower = char.ToLowerInvariant(c);
                var upper = char.ToUpperInvariant(c);
                var typed = char.ToString(shift ? upper : lower);
                return new KeyDefinition(typed, "Key" + char.ToString(upper), upper, typed);
            }
            if (c is >= '0' and <= '9')
            {
                var digit = char.ToString(c);
                return new KeyDefinition(digit, "Digit" + digit, c, digit);
            }
        }
        return null;
    }

    private static FrozenDictionary<string, KeyDefinition> BuildNamedKeys()
    {
        var keys = new Dictionary<string, KeyDefinition>(StringComparer.OrdinalIgnoreCase)
        {
            ["Enter"] = new("Enter", "Enter", 13, "\r"),
            ["Escape"] = new("Escape", "Escape", 27, null),
            ["Tab"] = new("Tab", "Tab", 9, null),
            ["Backspace"] = new("Backspace", "Backspace", 8, null),
            ["Delete"] = new("Delete", "Delete", 46, null),
            ["Insert"] = new("Insert", "Insert", 45, null),
            ["Space"] = new(" ", "Space", 32, " "),
            ["ArrowLeft"] = new("ArrowLeft", "ArrowLeft", 37, null),
            ["ArrowUp"] = new("ArrowUp", "ArrowUp", 38, null),
            ["ArrowRight"] = new("ArrowRight", "ArrowRight", 39, null),
            ["ArrowDown"] = new("ArrowDown", "ArrowDown", 40, null),
            ["Home"] = new("Home", "Home", 36, null),
            ["End"] = new("End", "End", 35, null),
            ["PageUp"] = new("PageUp", "PageUp", 33, null),
            ["PageDown"] = new("PageDown", "PageDown", 34, null),
            ["Plus"] = new("+", "Equal", 187, "+"),
            ["Minus"] = new("-", "Minus", 189, "-"),
        };
        for (var n = 1; n <= 12; n++)
        {
            keys["F" + n] = new KeyDefinition("F" + n, "F" + n, 111 + n, null);
        }
        return keys.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase);
    }
}
