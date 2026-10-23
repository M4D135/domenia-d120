using System.Text;

namespace Domenia.E2E.Runner;

/// <summary>Incremental evidence from the active journal and its one rotated predecessor; a lost boundary is a failed recipe.</summary>
internal sealed class JournalTail
{
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private readonly Lock gate = new();
    private readonly List<string> lines = [];
    private long offset;
    private byte[] anchor = [];
    private bool discardPartial;
    public string? Path { get; }
    public string? IntegrityError { get; private set; }

    private JournalTail(string? path) { Path = path; }
    public static string? DefaultPath()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return System.IO.Path.IsPathFullyQualified(root) ? System.IO.Path.Combine(root, "Domenia", "logs", "domenia.log") : null;
    }
    public static JournalTail FromNow() => FromPath(DefaultPath());
    internal static JournalTail FromPath(string? path)
    {
        var result = new JournalTail(path);
        if (path is null || !File.Exists(path)) { return result; }
        try
        {
            var bytes = Read(path); result.Advance(bytes, bytes.Length);
            result.discardPartial = bytes.Length > 0 && bytes[^1] != '\n';
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { result.IntegrityError = "Position initiale du journal non établie (" + ex.GetType().Name + ")."; }
        return result;
    }

    public IReadOnlyList<string> Lines()
    {
        lock (gate)
        {
            if (Path is null || !File.Exists(Path)) { return lines.ToArray(); }
            try
            {
                var bytes = Read(Path);
                if (!Matches(bytes))
                {
                    var archived = File.Exists(Path + ".1") ? Read(Path + ".1") : [];
                    if (Matches(archived)) { Collect(archived); }
                    else { IntegrityError ??= "Rotation ou remplacement du journal sans frontière retrouvée ; preuve E2E incomplète."; }
                    offset = 0; anchor = []; discardPartial = false;
                }
                Collect(bytes);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DecoderFallbackException)
            { IntegrityError ??= "Journal de recette illisible (" + ex.GetType().Name + ")."; }
            return lines.ToArray();
        }
    }
    private bool Matches(byte[] bytes) => bytes.LongLength >= offset && offset >= anchor.Length
        && bytes.AsSpan((int)offset - anchor.Length, anchor.Length).SequenceEqual(anchor);
    private void Collect(byte[] bytes)
    {
        var tail = bytes.AsSpan((int)offset);
        var end = tail.LastIndexOf((byte)'\n');
        if (end < 0) { return; }
        var text = Utf8.GetString(tail[..(end + 1)]);
        foreach (var line in text.Split('\n'))
        {
            if (discardPartial) { discardPartial = false; continue; }
            if (line.TrimEnd('\r') is not { Length: > 0 } record) { continue; }
            if (lines.Count >= 50_000) { IntegrityError ??= "Plus de 50 000 lignes de recette ; preuve bornée et incomplète."; break; }
            lines.Add(record);
        }
        Advance(bytes, checked((int)offset + end + 1));
    }
    private void Advance(byte[] bytes, int position)
    { offset = position; anchor = bytes.AsSpan(Math.Max(0, position - 256), Math.Min(position, 256)).ToArray(); }
    private static byte[] Read(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (stream.Length > 16 * 1024 * 1024) { throw new IOException("Journal hors limite de lecture."); }
        var bytes = new byte[stream.Length]; stream.ReadExactly(bytes); return bytes;
    }
}
