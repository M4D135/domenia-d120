using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// Durable write receipts in one JSON Lines file of the user data folder (docs/WRITES.md § 4): %LOCALAPPDATA%\Domenia\
/// receipts.jsonl, or receipts-simulation.jsonl in simulation (never shared with the directory mode). Operation class
/// LocalWrite: the directory is never written here.
/// <para>
/// Each line is one version of a receipt: <c>{"format":"domenia.receipt","version":1,"receipt":{…}}</c>, 64 KiB at most.
/// Appends are atomic: under a lock shared by every Domenia process of the machine, the whole line is written by one call on a
/// write-through stream and flushed to the disk; a line torn by a crash (no final line feed) is closed by the next append, so
/// it never swallows the next record. Reads fold bounded active and archived files afresh, including replacements with the
/// same length or timestamp. Torn, inconsistent or missing known records remain uncertain evidence and prevent new sends.
/// A file that cannot be read (locked, access denied, redirected, or total size above 64 MiB) raises <see cref="IOException"/>.
/// Completed receipts are archived before atomic compaction; unresolved receipts are never removed.
/// </para>
/// </summary>
public sealed partial class FileReceiptStore : IReceiptStore, IDisposable
{
    public const string DirectoryFileName = "receipts.jsonl";
    public const string SimulationFileName = "receipts-simulation.jsonl";
    public const string Format = "domenia.receipt";
    public const int Version = 1;

    /// <summary>Longest record line, line feed included.</summary>
    public const int MaxLineBytes = 65_536;

    /// <summary>Bounded total read budget for the active log and its archives; a larger journal requires manual review.</summary>
    public const long MaxFileBytes = 64L * 1024 * 1024;

    /// <summary>Longest wait for the lock held by another instance appending to the same file.</summary>
    public static readonly TimeSpan LockTimeout = TimeSpan.FromSeconds(5);

    private static readonly JsonSerializerOptions Json = CreateJson();

    private readonly string path;
    private readonly string lockName;
    private readonly ITechnicalJournal log;
    private readonly SemaphoreSlim gate = new(1, 1);
    // A missing record remains evidence in this instance; deletion must not turn a pending write into a healthy state.
    private readonly Dictionary<string, WriteReceipt> known = new(StringComparer.Ordinal);
    private int unreadableTraced;

    public FileReceiptStore(string path, ITechnicalJournal log)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(log);
        if (!Path.IsPathFullyQualified(path))
        {
            // Never relative to the current folder, which may be the share or key the pack runs from.
            throw new ArgumentException("The receipts path must be absolute.", nameof(path));
        }
        this.path = Path.GetFullPath(path);
        ValidateReceiptPath(this.path);
        this.log = log;
        lockName = LockNameFor(path);
    }

    /// <summary>File name of the mode: the simulation never reads nor writes the receipts of the directory mode.</summary>
    public static string FileNameFor(AppMode mode) => mode == AppMode.Simulation ? SimulationFileName : DirectoryFileName;

    /// <summary>Machine-wide lock of a receipts file: hash of the full path, case ignored (NTFS), so the name holds no user data.</summary>
    public static string LockNameFor(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        var full = Path.GetFullPath(path).ToUpperInvariant();
        return @"Global\Domenia.Receipts." + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(full)))[..32];
    }

    public bool Persistent => true;

    public async Task AppendAsync(WriteReceipt receipt, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        var line = Serialize(receipt);
        if (line.Length > MaxLineBytes || Parse(line.AsMemory(0, line.Length - 1)) is null)
        {
            throw new IOException("The receipt is invalid or larger than the longest record line.");
        }
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // One thread from start to end (the machine-wide lock belongs to the thread that took it), never the caller's.
            await Task.Run(() => Append(receipt, line), CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<ReceiptLog> ReadAllAsync(CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(Read, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    public void Dispose() => gate.Dispose();

    /// <summary>The record line of one version of a receipt, UTF-8, line feed included.</summary>
    public static byte[] Serialize(WriteReceipt receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = false }))
        {
            writer.WriteStartObject();
            writer.WriteString("format", Format);
            writer.WriteNumber("version", Version);
            writer.WritePropertyName("receipt");
            JsonSerializer.Serialize(writer, receipt, Json);
            writer.WriteEndObject();
        }
        buffer.WriteByte((byte)'\n');
        return buffer.ToArray();
    }

    /// <summary>One record line read back; null when it is not a receipt of this format (counted as unreadable).</summary>
    public static WriteReceipt? Parse(ReadOnlyMemory<byte> line)
    {
        try
        {
            using var document = JsonDocument.Parse(line, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("format", out var format) || format.ValueKind != JsonValueKind.String || format.GetString() != Format
                || !root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number != Version
                || !root.TryGetProperty("receipt", out var body) || body.ValueKind != JsonValueKind.Object)
            {
                return null;
            }
            if (DuplicateReceiptProperties(root)) { return null; }
            var receipt = body.Deserialize<WriteReceipt>(Json);
            return receipt is null ? null : Normalize(receipt);
        }
        catch (JsonException)
        {
            // The parser message may quote the line: a fixed reason only, counted by the caller.
            return null;
        }
        catch (NotSupportedException)
        {
            return null;
        }
    }

    private void Append(WriteReceipt receipt, byte[] line)
    {
        ProtectReceiptRoot();
        using var machineLock = new Mutex(initiallyOwned: false, lockName);
        if (!Acquire(machineLock))
        {
            throw new IOException("The receipts file is being written by another instance of Domenia.");
        }
        try
        {
            ValidateReceiptPath(path);
            // The last admission and the first durable receipt share one machine-wide critical section.
            // Another application instance cannot both observe an empty pending set and send a second write.
            if (receipt.Version == 1)
            {
                var before = ReadReceiptsLocked();
                if (before.Unreadable != 0 || before.Receipts.Any(r => WriteReceipts.IsPending(r) || r.Id == receipt.Id))
                { throw new IOException("Reçus incertains, illisibles ou identifiant déjà utilisé ; aucun nouvel envoi autorisé."); }
            }
            if (!File.Exists(path) && File.Exists(MarkerPath))
            { throw new IOException("Journal des reçus disparu ; aucun nouveau reçu ne peut remplacer les preuves antérieures."); }
            using (var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read, 4096, FileOptions.WriteThrough))
            {
                ProtectReceiptFile(path);
                if (stream.Length + line.Length > MaxFileBytes)
                {
                    throw new IOException("The receipts file reached its largest size.");
                }
                if (stream.Length > 0)
                {
                    stream.Seek(-1, SeekOrigin.End);
                    if (stream.ReadByte() != '\n')
                    {
                        // A line torn by a crash during an earlier append: closed here, so it never swallows this record.
                        stream.Seek(0, SeekOrigin.End);
                        stream.WriteByte((byte)'\n');
                        log.Warning($"Reçus {Path.GetFileName(path)} : dernière ligne interrompue fermée avant l’ajout.");
                    }
                }
                stream.Seek(0, SeekOrigin.End);
                stream.Write(line);
                stream.Flush(flushToDisk: true);
                EnsureReceiptMarker();
            }
            CompactReceipts();
        }
        finally
        {
            machineLock.ReleaseMutex();
        }
    }

    private bool Acquire(Mutex machineLock)
    {
        try
        {
            return machineLock.WaitOne(LockTimeout);
        }
        catch (AbandonedMutexException)
        {
            // The previous holder ended without releasing it: the lock is now ours. A torn line it may have left is closed by
            // this append.
            log.Warning("Verrou des reçus abandonné par une autre instance : repris.");
            return true;
        }
    }

    /// <summary>A receipt read back: identity and plan required, missing arrays as empty ones; anything else is unreadable.</summary>
    private static WriteReceipt? Normalize(WriteReceipt receipt)
    {
        var plan = receipt.Plan;
        if (!WritePlans.IsPlanId(receipt.Id) || receipt.Version < 1 || plan is null || plan.Target is null
            || !WritePlans.IsPlanId(plan.Id) || string.IsNullOrEmpty(plan.Kind) || !Guid.TryParse(plan.Target.ObjectGuid, out var target) || target == Guid.Empty
            || string.IsNullOrEmpty(receipt.Operator) || receipt.Operator != plan.Operator || receipt.Mode != plan.Mode || receipt.Simulated != plan.Simulated
            || plan.Confirmation is null || plan.Reversibility is null || plan.Changes.IsDefaultOrEmpty || plan.Changes.Length > WritePlans.MaxChanges
            || plan.Changes.Any(c => c is null || string.IsNullOrWhiteSpace(c.Attribute) || !Enum.IsDefined(c.Kind))
            || string.IsNullOrWhiteSpace(plan.Target.Dn) || string.IsNullOrWhiteSpace(plan.Target.Kind) || string.IsNullOrWhiteSpace(plan.Target.Name)
            || string.IsNullOrWhiteSpace(plan.Title) || string.IsNullOrWhiteSpace(plan.Label) || string.IsNullOrWhiteSpace(plan.Summary) || string.IsNullOrWhiteSpace(plan.Mode)
            || plan.ExpiresAt <= plan.CreatedAt || plan.Confirmation.TypedNameRequired && string.IsNullOrEmpty(plan.Confirmation.TypedName)
            || !plan.Risks.IsDefault && plan.Risks.Any(r => r is null || r.Text is null || !Enum.IsDefined(r.Tone))
            || !receipt.Details.IsDefault && receipt.Details.Any(d => d is null || d.Label is null || d.Value is null)
            || plan.Fingerprint is not { Length: 64 } || !plan.Fingerprint.All(char.IsAsciiHexDigit) || !WritePlans.IsIntact(plan)
            || receipt.SentAt < plan.CreatedAt || receipt.At < receipt.SentAt || receipt.CompletedAt < receipt.SentAt || receipt.VerifiedAt < receipt.SentAt
            || !Enum.IsDefined(receipt.Result) || !Enum.IsDefined(receipt.Verification))
        { return null; }
        return receipt with
        {
            Details = receipt.Details.IsDefault ? ImmutableArray<ReceiptDetail>.Empty : receipt.Details,
            Plan = plan with { Risks = plan.Risks.IsDefault ? ImmutableArray<WriteRisk>.Empty : plan.Risks },
        };
    }

    private static bool DuplicateReceiptProperties(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var properties = element.EnumerateObject().ToArray();
            return properties.Select(p => p.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != properties.Length
                || properties.Any(p => DuplicateReceiptProperties(p.Value));
        }
        return element.ValueKind == JsonValueKind.Array && element.EnumerateArray().Any(DuplicateReceiptProperties);
    }

    private static JsonSerializerOptions CreateJson()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.Never,
            WriteIndented = false,
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }
}
