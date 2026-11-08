namespace Domenia.Core;

/// <summary>Cheap conservative precheck shared by presentation sinks. False only when none of the mask
/// grammars can match. It never grants permission to export an attribute or persist a secret.</summary>
public static class SecretTextHints
{
    public const int MaximumTextLength = 1024 * 1024;
    private static readonly string[] Introducers = ["pass", "pwd", "mot", "secret", "token", "key", "authorization", "bearer", "basic", "\"p\"", "-p", "/p", "-rp", "/rp"];

    public static bool MayHoldSecret(string? text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        if (text.Length > MaximumTextLength) return true;
        foreach (var introducer in Introducers)
            if (text.Contains(introducer, StringComparison.OrdinalIgnoreCase)) return true;
        // Eight six-digit groups; Unicode digits remain covered by the regex's \d grammar.
        return text.Length >= 55 && text.Contains('-') && text.Any(char.IsDigit);
    }
}
