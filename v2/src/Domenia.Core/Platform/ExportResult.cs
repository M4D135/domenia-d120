namespace Domenia.Core;

/// <summary>
/// Result of a document asked by the operator (Assistance documents and dossiers, Opérations CSV, diagnostic and dossier):
/// written, or kept in memory only when the mode writes nothing (capture, E2E, no data folder), with its fingerprint.
/// </summary>
public sealed record ExportResult(bool Saved, string? Path, string Name, string? Folder, string Sha256, long Bytes, string Message, DateTimeOffset At);
