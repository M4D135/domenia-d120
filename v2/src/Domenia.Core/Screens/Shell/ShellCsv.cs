using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>A CSV document ready to be written: text, rows counted, what was masked or withheld.</summary>
public sealed record CsvDocument(string Text, int Rows, int Masked, ImmutableArray<string> Withheld);

/// <summary>A CSV file read back: delimiter found, headers and rows (bounded), whether rows were left out.</summary>
public sealed record CsvTable(char Delimiter, ImmutableArray<string> Headers, ImmutableArray<ImmutableArray<string>> Rows, int Total, bool Truncated);

/// <summary>
/// The CSV rules of Domenia (Domenia 1 Export-DomeniaCsv, ConvertTo-DomeniaSpreadsheetCell, Get-DomeniaExportFileName,
/// Get-DomeniaCsvDelimiter, TRV-054 and TRV-055): semicolon, French headers, formula-like cells neutralized, secret columns
/// withheld and secret-looking text masked, names « Domenia-&lt;OU ou poste&gt;-AAAAMMJJ-HHmm.csv ». Pure.
/// </summary>
public static partial class ShellCsv
{
    public const char Separator = ';';

    /// <summary>Rows read back from a file at most.</summary>
    public const int MaxReadRows = 5000;

    /// <summary>Columns read back from a file at most.</summary>
    public const int MaxReadColumns = 200;

    private static readonly char[] QuoteTriggers = [Separator, '"', '\r', '\n'];
    private static readonly char[] LineBreaks = ['\r', '\n'];

    /// <summary>
    /// A text cell that a spreadsheet would read as a formula (« = + - @ », their full-width forms, after blanks or format
    /// characters, or a leading tab or line break) gets a leading apostrophe. Numbers, booleans and dates are written as they are.
    /// </summary>
    public static string Neutralize(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value ?? "";
        }
        return FormulaStart().IsMatch(value) || value[0] is '\t' or '\r' or '\n' ? "'" + value : value;
    }

    /// <summary>One cell, quoted when it holds the separator, a quote or a line break (quotes doubled).</summary>
    public static string Quote(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return value.IndexOfAny(QuoteTriggers) >= 0 ? "\"" + value.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"" : value;
    }

    /// <summary>
    /// The CSV text of a table: headers then rows, each cell neutralized and quoted. A column whose header names a secret
    /// attribute, or listed in <paramref name="secretColumns"/>, is withheld whatever it holds; every other text cell is masked
    /// when it looks like a secret. Lines end with CRLF (Excel).
    /// </summary>
    public static CsvDocument Build(IReadOnlyList<string> headers, IReadOnlyList<IReadOnlyList<string?>> rows, IReadOnlySet<int>? secretColumns = null)
    {
        ArgumentNullException.ThrowIfNull(headers);
        ArgumentNullException.ThrowIfNull(rows);
        var secret = new bool[headers.Count];
        var withheld = ImmutableArray.CreateBuilder<string>();
        for (var i = 0; i < headers.Count; i++)
        {
            secret[i] = (secretColumns?.Contains(i) ?? false) || ShellSecrets.IsSecretAttribute(headers[i]);
            if (secret[i])
            {
                withheld.Add(headers[i]);
            }
        }
        var masked = 0;
        var builder = new StringBuilder();
        builder.Append(string.Join(Separator, headers.Select(h => Quote(Neutralize(h))))).Append("\r\n");
        foreach (var row in rows)
        {
            var cells = new string[headers.Count];
            for (var i = 0; i < headers.Count; i++)
            {
                var value = i < row.Count ? row[i] ?? "" : "";
                if (secret[i])
                {
                    if (value.Length > 0)
                    {
                        masked++;
                    }
                    value = ShellSecrets.WithheldValue;
                }
                else if (ShellSecrets.MayHoldSecret(value))
                {
                    var clean = ShellSecrets.Protect(value);
                    if (!string.Equals(clean, value, StringComparison.Ordinal))
                    {
                        masked++;
                    }
                    value = clean;
                }
                cells[i] = Quote(Neutralize(value));
            }
            builder.Append(string.Join(Separator, cells)).Append("\r\n");
        }
        return new CsvDocument(builder.ToString(), rows.Count, masked, withheld.ToImmutable());
    }

    /// <summary>
    /// File name of an export (Domenia 1 Get-DomeniaExportFileName): the subject keeps letters, digits, dot, dash and
    /// underscore (60 characters at most), « export » when nothing is left.
    /// </summary>
    public static string FileName(string? subject, DateTime localTime, string extension = "csv")
    {
        ArgumentException.ThrowIfNullOrEmpty(extension);
        var clean = Unsafe().Replace((subject ?? "").Trim(), "-").Trim('-', '.');
        if (clean.Length > 60)
        {
            clean = clean[..60].Trim('-', '.');
        }
        if (clean.Length == 0)
        {
            clean = "export";
        }
        return "Domenia-" + clean + "-" + localTime.ToString("yyyyMMdd'-'HHmm", CultureInfo.InvariantCulture) + "." + extension;
    }

    /// <summary>
    /// Delimiter of a CSV written by Domenia (semicolon) or by another tool (comma), from its first line (Domenia 1
    /// Get-DomeniaCsvDelimiter): semicolon when it has semicolons and no comma, or more semicolons than commas.
    /// </summary>
    public static char DetectDelimiter(string? firstLine)
    {
        var line = firstLine ?? "";
        var semicolons = line.Count(c => c == ';');
        var commas = line.Count(c => c == ',');
        return (semicolons > 0 && commas == 0) || semicolons > commas ? ';' : ',';
    }

    /// <summary>
    /// Reads a CSV text (byte order mark removed by the caller): delimiter from the first line, quoted cells with doubled quotes
    /// and line breaks, at most <see cref="MaxReadRows"/> rows of <see cref="MaxReadColumns"/> columns; the count of rows
    /// left out is reported, never hidden. The leading apostrophe of a neutralized cell is kept (the text is shown as written).
    /// </summary>
    public static CsvTable Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var end = text.IndexOfAny(LineBreaks);
        var delimiter = DetectDelimiter(end < 0 ? text : text[..end]);
        var records = new List<List<string>>();
        var current = new List<string>();
        var cell = new StringBuilder();
        var quoted = false;
        var total = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (quoted)
            {
                if (c == '"')
                {
                    if (i + 1 < text.Length && text[i + 1] == '"')
                    {
                        cell.Append('"');
                        i++;
                    }
                    else
                    {
                        quoted = false;
                    }
                }
                else
                {
                    cell.Append(c);
                }
                continue;
            }
            if (c == '"' && cell.Length == 0)
            {
                quoted = true;
            }
            else if (c == delimiter)
            {
                AddCell(current, cell);
            }
            else if (c is '\r' or '\n')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n')
                {
                    i++;
                }
                AddCell(current, cell);
                total += AddRecord(records, current);
                current = [];
            }
            else
            {
                cell.Append(c);
            }
        }
        if (cell.Length > 0 || current.Count > 0)
        {
            AddCell(current, cell);
            total += AddRecord(records, current);
        }
        if (records.Count == 0)
        {
            return new CsvTable(delimiter, [], [], 0, false);
        }
        var headers = records[0].Take(MaxReadColumns).ToImmutableArray();
        var rows = records.Skip(1).Select(r => r.Take(MaxReadColumns).ToImmutableArray()).ToImmutableArray();
        var dataRows = Math.Max(0, total - 1);
        return new CsvTable(delimiter, headers, rows, dataRows, dataRows > rows.Length || records[0].Count > MaxReadColumns);
    }

    private static void AddCell(List<string> record, StringBuilder cell)
    {
        record.Add(cell.ToString());
        cell.Clear();
    }

    /// <summary>Keeps the record within the bound (header plus <see cref="MaxReadRows"/> rows); blank lines are not records.</summary>
    private static int AddRecord(List<List<string>> records, List<string> record)
    {
        if (record.Count == 1 && record[0].Length == 0)
        {
            return 0;
        }
        if (records.Count <= MaxReadRows)
        {
            records.Add(record);
        }
        return 1;
    }

    [GeneratedRegex(@"^[\s\p{Cf}]*[=+@\-＝＋－＠]")]
    private static partial Regex FormulaStart();

    [GeneratedRegex(@"[^\p{L}\p{Nd}._-]+")]
    private static partial Regex Unsafe();
}
