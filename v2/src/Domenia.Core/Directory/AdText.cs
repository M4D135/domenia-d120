using System.Buffers;
using System.Globalization;
using System.Text;

namespace Domenia.Core;

/// <summary>
/// The values read in the directory, prepared for the operator (Domenia 1 ConvertTo-DomeniaFlatText and the reading rules of
/// Domenia-Common.Model.ps1): one bounded line, and a UTF-8 text where an invalid octet stays visible instead of hiding
/// behind a replacement character. A flattened label is a display value only, never a delimiter of the perimeter. Pure.
/// </summary>
public static class AdText
{
    /// <summary>Length of a flattened value shown to the operator (Domenia 1: 240 characters).</summary>
    public const int FlatMaximum = 240;

    /// <summary>One line, white space collapsed, bounded at <paramref name="maximum"/> characters: a cut is shown by « … », never silent.</summary>
    public static string Flat(string? text, int maximum = FlatMaximum)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maximum, 1);
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        var builder = new StringBuilder(Math.Min(text.Length, Math.Min(maximum, 1024)));
        var pendingSpace = false;
        foreach (var c in text)
        {
            if (char.IsControl(c) || char.IsWhiteSpace(c))
            {
                pendingSpace = builder.Length > 0;
                continue;
            }
            if (pendingSpace)
            {
                builder.Append(' ');
                pendingSpace = false;
            }
            builder.Append(c);
            if (builder.Length > maximum) { break; }
        }
        var flat = builder.ToString();
        if (flat.Length <= maximum) { return flat; }
        var end = maximum - 1;
        if (end > 0 && char.IsHighSurrogate(flat[end - 1])) { end--; }
        return flat[..end] + "…";
    }

    /// <summary>
    /// UTF-8 text of octets read in the directory. A valid text is decoded exactly like <see cref="Encoding.UTF8.GetString(byte[])"/>;
    /// an invalid octet is kept visible as « \xNN » instead of a replacement character, so an unreadable byte is still told.
    /// </summary>
    public static string DecodeUtf8(ReadOnlySpan<byte> bytes)
    {
        if (bytes.IsEmpty)
        {
            return "";
        }
        var builder = new StringBuilder(bytes.Length);
        while (!bytes.IsEmpty)
        {
            if (Rune.DecodeFromUtf8(bytes, out var rune, out var consumed) == OperationStatus.Done)
            {
                builder.Append(rune.ToString());
                bytes = bytes[consumed..];
            }
            else
            {
                // Preserve every invalid byte, including overlong, surrogate and out-of-range sequences.
                builder.Append("\\x").Append(bytes[0].ToString("X2", CultureInfo.InvariantCulture));
                bytes = bytes[1..];
            }
        }
        return builder.ToString();
    }
}
