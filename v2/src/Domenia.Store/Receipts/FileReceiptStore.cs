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
/// it never swallows the next record. Reads are incremental (only the bytes added since the last read) and fold the versions
/// by identifier, the latest winning. A line that cannot be read is counted and traced, never fatal: the only line a crash can
/// tear is the last one being written, and the version 1 of a receipt (written before sending) is complete before anything is
/// sent. A file that cannot be read for now (locked, access denied, larger than 64 MiB) raises <see cref="IOException"/>: the
/// circuit then refuses new writes (fail closed).
/// </para>
/// </summary>
public sealed class FileReceiptStore : IReceiptStore, IDisposable
{
    public const string DirectoryFileName = "receipts.jsonl";
    public const string SimulationFileName = "receipts-simulation.jsonl";
    public const string Format = "domenia.receipt";
    public const int Version = 1;

    /// <summary>Longest record line, line feed included.</summary>
    public const int MaxLineBytes = 65_536;

    /// <summary>Larger files are not read and not extended (compaction comes with the Opérations screen, Domenia 1 TRV-283).</summary>
    public const long MaxFileBytes = 64L * 1024 * 1024;

    /// <summary>Longest wait for the lock held by another instance appending to the same file.</summary>
    public static readonly TimeSpan LockTimeout = TimeSpan.FromSeconds(5);

    private static readonly JsonSerializerOptions Json = CreateJson();

    private readonly string path;
    private readonly string lockName;
    private readonly ITechnicalJournal log;
    private readonly SemaphoreSlim gate = new(1, 1);
    // Incremental reading: bytes already folded, latest version of each receipt, lines that could not be read.
    private readonly Dictionary<string, WriteReceipt> latest = new(StringComparer.Ordinal);
    private long offset;
    private int unreadable;
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
        this.path = path;
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
        if (line.Length > MaxLineBytes)
        {
            throw new IOException("The receipt is larger than the longest record line.");
        }
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // One thread from start to end (the machine-wide lock belongs to the thread that took it), never the caller's.
            await Task.Run(() => Append(line), CancellationToken.None).ConfigureAwait(false);
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

    private void Append(byte[] line)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var machineLock = new Mutex(initiallyOwned: false, lockName);
        if (!Acquire(machineLock))
        {
            throw new IOException("The receipts file is being written by another instance of Domenia.");
        }
        try
        {
            using var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read, 4096, FileOptions.WriteThrough);
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

    private ReceiptLog Read()
    {
        var info = new FileInfo(path);
        if (!info.Exists)
        {
            Reset();
            return new ReceiptLog([], 0);
        }
        if (info.Length > MaxFileBytes)
        {
            log.Warning($"Reçus {Path.GetFileName(path)} non lus : fichier de plus de 64 Mio, aucune écriture n’est admise.");
            throw new IOException("The receipts file is larger than the largest readable size.");
        }
        if (info.Length < offset)
        {
            // Replaced or cut by hand: read again from the start, nothing is assumed from before.
            log.Warning($"Reçus {Path.GetFileName(path)} raccourcis depuis la dernière lecture : relus depuis le début.");
            Reset();
        }
        byte[] added;
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(offset, SeekOrigin.Begin);
            added = new byte[stream.Length - offset];
            stream.ReadExactly(added);
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
        {
            Reset();
            return new ReceiptLog([], 0);
        }
        var consumed = 0;
        var bytes = added.AsMemory();
        while (consumed < bytes.Length)
        {
            var end = bytes.Span[consumed..].IndexOf((byte)'\n');
            if (end < 0)
            {
                // Incomplete last line (being written, or torn): left for a later read.
                break;
            }
            var line = bytes.Slice(consumed, end);
            consumed += end + 1;
            if (line.Length > 0 && line.Span[^1] == (byte)'\r')
            {
                line = line[..^1];
            }
            if (line.IsEmpty)
            {
                continue;
            }
            if (line.Length >= MaxLineBytes || Parse(line) is not { } receipt)
            {
                unreadable++;
                continue;
            }
            if (!latest.TryGetValue(receipt.Id, out var known) || known.Version <= receipt.Version)
            {
                latest[receipt.Id] = receipt;
            }
        }
        offset += consumed;
        if (unreadable > unreadableTraced)
        {
            log.Warning($"Reçus {Path.GetFileName(path)} : {unreadable} enregistrement(s) illisible(s) ignoré(s).");
            unreadableTraced = unreadable;
        }
        return new ReceiptLog([.. latest.Values], unreadable);
    }

    private void Reset()
    {
        latest.Clear();
        offset = 0;
        unreadable = 0;
        unreadableTraced = 0;
    }

    /// <summary>A receipt read back: identity and plan required, missing arrays as empty ones; anything else is unreadable.</summary>
    private static WriteReceipt? Normalize(WriteReceipt receipt)
    {
        var plan = receipt.Plan;
        if (!WritePlans.IsPlanId(receipt.Id) || receipt.Version < 1 || plan is null || plan.Target is null
            || string.IsNullOrEmpty(plan.Kind) || string.IsNullOrEmpty(plan.Target.ObjectGuid) || string.IsNullOrEmpty(receipt.Operator)
            || string.IsNullOrEmpty(receipt.Mode) || plan.Confirmation is null || plan.Reversibility is null)
        {
            return null;
        }
        return receipt with
        {
            Details = receipt.Details.IsDefault ? ImmutableArray<ReceiptDetail>.Empty : receipt.Details,
            Plan = plan with
            {
                Changes = plan.Changes.IsDefault ? ImmutableArray<WriteChange>.Empty : plan.Changes,
                Risks = plan.Risks.IsDefault ? ImmutableArray<WriteRisk>.Empty : plan.Risks,
            },
        };
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
