using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>One record of an inventory file, whatever its adapter (Domenia 1 New-DomeniaInventoryRecord).</summary>
public sealed record RelationInventoryRecord(
    RelationImportAdapter Adapter,
    int Record,
    string User,
    string Computer,
    string When,
    bool UnixTime,
    string Serial,
    string FileSource,
    string Details,
    string Reject);

/// <summary>Date of a record: the UTC instant when readable, and a note when the file date was not trusted.</summary>
public sealed record RelationRecordWhen(string Text, DateTimeOffset? Utc, string Note);

/// <summary>Decision of the source priority inside one file (Domenia 1 Resolve-DomeniaInventoryPriority).</summary>
public sealed record RelationPriorityDecision(string Kind, string Reason);

/// <summary>Status of one preview row (Domenia 1 Get-DomeniaLinkImportStatus).</summary>
public sealed record RelationImportStatus(string Status, string Category, string Reason, bool Import, bool Verified);

/// <summary>A user or workstation of the local index, by exact name (Domenia 1 LocalIndexRead ResolveNames).</summary>
public sealed record RelationIndexEntry(Guid Guid, string Dn, string Name);

/// <summary>
/// Pure rules of the association import (port of Domenia-InventoryImport.Model.ps1 and of the import part of
/// Domenia-Relations.Model.ps1, Domenia 1 CO-08, points 137 and 138): explicit adapters (generic CSV, GLPI export, osquery
/// results), identity matching, dates, source priority inside the file, statuses of the preview, rollback batch. No disk, no
/// network: the page sends the text of the file chosen by the operator, the local index is given by the caller.
/// </summary>
public static partial class RelationImport
{
    /// <summary>Most records read from one file.</summary>
    public const int MaxRecords = 20_000;

    /// <summary>Rows shown in a preview.</summary>
    public const int PreviewRecords = 1_000;

    /// <summary>Associations written by one import (one plan of the write circuit).</summary>
    public const int BatchLimit = 64;

    /// <summary>A file date later than now by more than this is never trusted (it would win the priority of the file).</summary>
    public static readonly TimeSpan FutureTolerance = TimeSpan.FromMinutes(60);

    /// <summary>Largest CSV text, in characters (8 Mio in Domenia 1).</summary>
    public const int MaxCsvCharacters = 8 * 1024 * 1024;

    /// <summary>Largest osquery text, in characters (2 Mio in Domenia 1).</summary>
    public const int MaxJsonCharacters = 2 * 1024 * 1024;

    private static string C => FrenchText.Colon;

    /// <summary>The adapters; the provenance (Source) is imposed by the one the operator chose, never read from the file.</summary>
    public static ImmutableArray<RelationAdapterInfo> Adapters { get; } =
    [
        new(RelationImportAdapter.Csv, "CSV générique", "Import CSV", ".csv,text/csv",
            "Colonnes UserLogin (ou User, Username, SamAccountName) et Computer (ou ComputerName, Hostname), date ISO facultative When.", MaxCsvCharacters),
        new(RelationImportAdapter.Glpi, "Export GLPI (CSV)", "Import GLPI", ".csv,text/csv",
            "Export CSV de la liste des ordinateurs GLPI" + FrenchText.Colon + "Nom, Usager (ou Login), date du dernier inventaire ou de dernière modification, numéro de série.", MaxCsvCharacters),
        new(RelationImportAdapter.Osquery, "Résultats osquery (JSON)", "Import osquery", ".json,.jsonl,.log,application/json",
            "Table logged_in_users" + FrenchText.Colon + "journal de résultats osqueryd (une ligne JSON par événement) ou tableau d’osqueryi --json avec une colonne hostname.", MaxJsonCharacters),
    ];

    public static RelationAdapterInfo Adapter(RelationImportAdapter id) => Adapters.First(a => a.Id == id);

    /// <summary>Exact known GUID, or the legacy Windows name only when no GUID was stored.</summary>
    public static bool SameComputer(StoredRelation relation, Guid? guid, string name) => relation.ComputerGuid is { } id
        ? guid == id : RelationRules.ComputerKey(relation.Computer) == RelationRules.ComputerKey(name);

    // ------------------------------------------------------------------ CSV

    /// <summary>
    /// Delimiter of a CSV (Domenia 1 Get-DomeniaCsvDelimiter): Domenia exports use the semicolon, older exports and other tools
    /// the comma.
    /// </summary>
    public static char Delimiter(string firstLine)
    {
        ArgumentNullException.ThrowIfNull(firstLine);
        if (firstLine.Contains(';', StringComparison.Ordinal) && !firstLine.Contains(',', StringComparison.Ordinal))
        {
            return ';';
        }
        return firstLine.Split(';').Length > firstLine.Split(',').Length ? ';' : ',';
    }

    /// <summary>
    /// Reads a CSV text into records keyed by header (RFC 4180 quotes, doubled quotes, multi-line quoted fields, BOM). Blank
    /// lines are skipped: records are numbered by record, not by line, like Import-Csv.
    /// </summary>
    public static (ImmutableArray<IReadOnlyDictionary<string, string>> Rows, int Total, bool Truncated) ParseCsv(string text, int maxRecords = MaxRecords)
    {
        ArgumentNullException.ThrowIfNull(text);
        var body = text.Length > 0 && text[0] == '﻿' ? text[1..] : text;
        var newline = body.IndexOfAny(['\r', '\n']);
        var delimiter = Delimiter(newline < 0 ? body : body[..newline]);
        var records = ReadFields(body, delimiter);
        if (records.Count == 0)
        {
            return ([], 0, false);
        }
        var headers = records[0].Select(h => h.Trim()).ToArray();
        var rows = ImmutableArray.CreateBuilder<IReadOnlyDictionary<string, string>>();
        var total = 0;
        var truncated = false;
        foreach (var fields in records.Skip(1))
        {
            if (fields.All(string.IsNullOrWhiteSpace))
            {
                continue;
            }
            total++;
            if (rows.Count >= maxRecords)
            {
                truncated = true;
                continue;
            }
            var row = new Dictionary<string, string>(StringComparer.Ordinal);
            for (var i = 0; i < headers.Length; i++)
            {
                if (headers[i].Length > 0 && !row.ContainsKey(headers[i]))
                {
                    row[headers[i]] = i < fields.Count ? fields[i] : "";
                }
            }
            rows.Add(row);
        }
        return (rows.ToImmutable(), total, truncated);
    }

    private static List<List<string>> ReadFields(string text, char delimiter)
    {
        var records = new List<List<string>>();
        var fields = new List<string>();
        var field = new StringBuilder();
        var quoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (quoted)
            {
                if (c == '"')
                {
                    if (i + 1 < text.Length && text[i + 1] == '"')
                    {
                        field.Append('"');
                        i++;
                    }
                    else
                    {
                        quoted = false;
                    }
                }
                else
                {
                    field.Append(c);
                }
                continue;
            }
            if (c == '"' && field.Length == 0)
            {
                quoted = true;
            }
            else if (c == delimiter)
            {
                fields.Add(field.ToString());
                field.Clear();
            }
            else if (c is '\r' or '\n')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n')
                {
                    i++;
                }
                fields.Add(field.ToString());
                field.Clear();
                records.Add(fields);
                fields = [];
            }
            else
            {
                field.Append(c);
            }
        }
        if (field.Length > 0 || fields.Count > 0)
        {
            fields.Add(field.ToString());
            records.Add(fields);
        }
        return records;
    }

    /// <summary>Comparable column name: lower case, without accents, apostrophes unified, separators collapsed to one space.</summary>
    public static string HeaderKey(string? name)
    {
        var folded = FrenchText.Fold(name ?? "").Replace('`', '\'');
        return SeparatorPattern().Replace(folded, " ").Trim();
    }

    /// <summary>First non-empty value among the aliases, and the column it came from.</summary>
    public static (string Value, string Column) Column(IReadOnlyDictionary<string, string> row, params string[] aliases)
    {
        ArgumentNullException.ThrowIfNull(row);
        ArgumentNullException.ThrowIfNull(aliases);
        var columns = new Dictionary<string, KeyValuePair<string, string>>(StringComparer.Ordinal);
        foreach (var pair in row)
        {
            columns.TryAdd(HeaderKey(pair.Key), pair);
        }
        foreach (var alias in aliases)
        {
            if (columns.TryGetValue(HeaderKey(alias), out var found) && found.Value.Trim().Length > 0)
            {
                return (found.Value.Trim(), found.Key);
            }
        }
        return ("", "");
    }

    /// <summary>Generic CSV: the historical columns of the association import (Domenia 1 ConvertFrom-DomeniaLinkCsvRow).</summary>
    public static RelationInventoryRecord CsvRow(IReadOnlyDictionary<string, string> row, int record)
    {
        ArgumentNullException.ThrowIfNull(row);
        var user = Column(row, "UserLogin", "User", "Username", "LastUser", "SamAccountName").Value;
        var computer = Column(row, "Computer", "ComputerName", "Hostname", "Host", "Machine", "Name").Value;
        return new RelationInventoryRecord(RelationImportAdapter.Csv, record, user, computer, Column(row, "When").Value, false, "",
            Column(row, "Source").Value, Column(row, "Details").Value, "");
    }

    /// <summary>
    /// GLPI computer list export: the login comes from Usager / Login; the User column of GLPI may hold a display name
    /// (« Dupont Alice »), which is never taken as a login.
    /// </summary>
    public static RelationInventoryRecord GlpiRow(IReadOnlyDictionary<string, string> row, int record)
    {
        ArgumentNullException.ThrowIfNull(row);
        var computer = Column(row, "Nom", "Name", "Ordinateur", "Computer", "Nom de l’ordinateur").Value;
        var login = Column(row, "Usager", "Alternate username", "Login", "Identifiant", "Nom d’usager", "Nom d’utilisateur", "User login", "Contact");
        var reject = "";
        if (login.Value.Length == 0)
        {
            login = Column(row, "Utilisateur", "User");
            if (login.Value.Any(char.IsWhiteSpace))
            {
                reject = "Nom affiché (" + FrenchText.Quote(login.Value) + ")" + C + "identifiant de connexion absent. Exportez la colonne Usager ou Login de GLPI.";
            }
        }
        var when = Column(row, "Dernière date d’inventaire", "Date du dernier inventaire", "Dernier inventaire", "Last inventory date", "Last inventory",
            "Last inventory update", "Dernière modification", "Last update", "Date de modification");
        var serial = Column(row, "Numéro de série", "Serial number", "Serial").Value;
        var entity = Column(row, "Entité", "Entity").Value;
        var details = "";
        if (serial.Length > 0)
        {
            details = "Numéro de série GLPI" + C + serial + ".";
        }
        if (entity.Length > 0)
        {
            details = (details + " Entité GLPI" + C + entity + ".").Trim();
        }
        if (when.Column.Length > 0)
        {
            details = (details + " Date lue dans " + FrenchText.Quote(when.Column) + ".").Trim();
        }
        return new RelationInventoryRecord(RelationImportAdapter.Glpi, record, login.Value, computer, when.Value, false, serial, "", details, reject);
    }

    // ------------------------------------------------------------------ osquery

    /// <summary>
    /// osquery logged_in_users results: osqueryd results log (one JSON object per line, « columns » or « snapshot ») or the
    /// JSON array of osqueryi --json. Session ends, session types without a user and sessions without a person are skipped and
    /// counted; bounded by <paramref name="maxRecords"/>.
    /// </summary>
    public static (string Format, ImmutableArray<RelationInventoryRecord> Records, int Rejected, int Skipped, bool Truncated) ParseOsquery(string text, int maxRecords = MaxRecords)
    {
        ArgumentNullException.ThrowIfNull(text);
        var trimmed = text.Trim().TrimStart('﻿');
        if (trimmed.Length == 0)
        {
            return ("", [], 0, 0, false);
        }
        var entries = new List<(int Line, JsonElement Entry)>();
        var rejected = 0;
        var format = trimmed.StartsWith('[') ? "array" : "resultsLog";
        var documents = new List<JsonDocument>();
        try
        {
            if (format == "array")
            {
                try
                {
                    var document = JsonDocument.Parse(trimmed);
                    documents.Add(document);
                    var line = 0;
                    foreach (var item in document.RootElement.EnumerateArray())
                    {
                        entries.Add((++line, item));
                    }
                }
                catch (JsonException)
                {
                    rejected++;
                }
            }
            else
            {
                var lines = trimmed.Split('\n');
                for (var i = 0; i < lines.Length; i++)
                {
                    var current = lines[i].Trim();
                    if (current.Length == 0)
                    {
                        continue;
                    }
                    try
                    {
                        var document = JsonDocument.Parse(current);
                        documents.Add(document);
                        entries.Add((i + 1, document.RootElement));
                    }
                    catch (JsonException)
                    {
                        rejected++;
                    }
                }
            }
            string[] sessionTypes = ["user", "active", "connected", "disconnected", "idle"];
            var records = ImmutableArray.CreateBuilder<RelationInventoryRecord>();
            var skipped = 0;
            var truncated = false;
            foreach (var (line, entry) in entries)
            {
                if (entry.ValueKind != JsonValueKind.Object)
                {
                    rejected++;
                    continue;
                }
                if (Member(entry, "action") == "removed")
                {
                    skipped++;
                    continue;
                }
                var host = Member(entry, "hostIdentifier", "host_identifier");
                var eventTime = Member(entry, "unixTime");
                var rows = new List<JsonElement>();
                if (entry.TryGetProperty("columns", out var columns) && columns.ValueKind == JsonValueKind.Object)
                {
                    rows.Add(columns);
                }
                else if (entry.TryGetProperty("snapshot", out var snapshot) && snapshot.ValueKind == JsonValueKind.Array)
                {
                    rows.AddRange(snapshot.EnumerateArray());
                }
                else
                {
                    rows.Add(entry);
                }
                foreach (var row in rows)
                {
                    if (row.ValueKind != JsonValueKind.Object)
                    {
                        continue;
                    }
                    var type = Member(row, "type");
                    if (type.Length > 0 && !sessionTypes.Contains(type.ToLowerInvariant()))
                    {
                        skipped++;
                        continue;
                    }
                    var user = Member(row, "user", "username");
                    if (user.Length == 0 || NonPersonPattern().IsMatch(user))
                    {
                        skipped++;
                        continue;
                    }
                    if (records.Count >= maxRecords)
                    {
                        truncated = true;
                        break;
                    }
                    var computer = Member(row, "hostname", "computer_name", "host_identifier", "hostIdentifier");
                    if (computer.Length == 0)
                    {
                        computer = host;
                    }
                    var loginTime = Member(row, "time");
                    var when = eventTime;
                    var details = "Relevé osquery";
                    if (UnixPattern().IsMatch(loginTime))
                    {
                        when = loginTime;
                        details = "Ouverture de session osquery";
                    }
                    details += ", ligne " + line.ToString(CultureInfo.InvariantCulture) + (format == "array" ? " du tableau." : " du journal.");
                    if (type.Length > 0)
                    {
                        details += " Type de session" + C + type + ".";
                    }
                    var reject = computer.Length == 0
                        ? "Poste absent" + C + "ajoutez la colonne hostname (table system_info) ou importez le journal de résultats osqueryd."
                        : "";
                    records.Add(new RelationInventoryRecord(RelationImportAdapter.Osquery, records.Count + 1, user, computer, when, true, "", "", details, reject));
                }
                if (truncated)
                {
                    break;
                }
            }
            return (format, records.ToImmutable(), rejected, skipped, truncated);
        }
        finally
        {
            foreach (var document in documents)
            {
                document.Dispose();
            }
        }
    }

    private static string Member(JsonElement element, params string[] names)
    {
        foreach (var name in names)
        {
            if (element.TryGetProperty(name, out var value))
            {
                var text = value.ValueKind switch
                {
                    JsonValueKind.String => value.GetString() ?? "",
                    JsonValueKind.Number => value.GetRawText(),
                    _ => "",
                };
                if (text.Trim().Length > 0)
                {
                    return text.Trim();
                }
            }
        }
        return "";
    }

    // ------------------------------------------------------------------ identity, dates, priority

    /// <summary>
    /// Identity matching before the local index lookup (Domenia 1 Test-DomeniaInventoryIdentity): a qualified name of another
    /// domain, a UPN of another suffix, a FQDN of another domain, an IP address or a hardware UUID are rejected, never cut.
    /// Returns the reason of the rejection, or an empty text.
    /// </summary>
    public static string Identity(string? user, string? computer, string? domainDns, string? netbios)
    {
        var dns = (domainDns ?? "").Trim().TrimEnd('.').ToLowerInvariant();
        var shortName = (netbios ?? "").Trim().ToLowerInvariant();
        var label = dns.Contains('.', StringComparison.Ordinal) ? dns[..dns.IndexOf('.', StringComparison.Ordinal)] : dns;
        var u = (user ?? "").Trim();
        var c = (computer ?? "").Trim().TrimEnd('.');
        var slash = u.IndexOf('\\', StringComparison.Ordinal);
        if (slash >= 0)
        {
            var authority = u[..slash].Trim().ToLowerInvariant();
            if (dns.Length == 0 && shortName.Length == 0)
            {
                return "Compte qualifié (" + u + ")" + C + "domaine courant inconnu, correspondance non vérifiable.";
            }
            if (authority != shortName && authority != label && authority != dns)
            {
                return "Compte d’un autre domaine (" + u + ")" + C + "ligne non importée.";
            }
        }
        else if (u.Contains('@', StringComparison.Ordinal))
        {
            var suffix = u[(u.IndexOf('@', StringComparison.Ordinal) + 1)..].Trim().ToLowerInvariant();
            if (dns.Length == 0)
            {
                return "Compte au format UPN (" + u + ")" + C + "domaine courant inconnu, correspondance non vérifiable.";
            }
            if (suffix != dns)
            {
                return "Suffixe UPN différent du domaine (" + u + ")" + C + "correspondance non vérifiable, ligne non importée.";
            }
        }
        if (IpPattern().IsMatch(c))
        {
            return "Adresse IP (" + c + ") au lieu d’un nom de poste" + C + "ligne non importée.";
        }
        if (c.Contains('.', StringComparison.Ordinal))
        {
            var suffix = c[(c.IndexOf('.', StringComparison.Ordinal) + 1)..].ToLowerInvariant();
            if (dns.Length == 0)
            {
                return "Nom DNS complet (" + c + ")" + C + "domaine courant inconnu, correspondance non vérifiable.";
            }
            if (suffix != dns)
            {
                return "Poste d’un autre domaine DNS (" + c + ")" + C + "ligne non importée.";
            }
        }
        if (UuidPattern().IsMatch(c))
        {
            return "Identifiant matériel (" + c + ") au lieu d’un nom de poste" + C + "configurez host_identifier=hostname dans osquery ou ajoutez la colonne hostname.";
        }
        return "";
    }

    /// <summary>Workstation name as stored: first label, no « $ », upper case (Domenia 1 Normalize-LinkComputer).</summary>
    public static string NormalizeComputer(string? computer)
    {
        var c = (computer ?? "").Trim().Trim('"', ' ', '\t', '\r', '\n');
        if (c.Length == 0)
        {
            return "";
        }
        if (c.EndsWith('$'))
        {
            c = c[..^1];
        }
        var dot = c.IndexOf('.', StringComparison.Ordinal);
        return (dot >= 0 ? c[..dot] : c).ToUpperInvariant();
    }

    /// <summary>
    /// Login as stored (Domenia 1 Normalize-LinkUser): authority and UPN suffix removed; machine accounts, system identities and
    /// the built-in administrator give an empty text.
    /// </summary>
    public static string NormalizeUser(string? user)
    {
        var u = (user ?? "").Trim().Trim('"', ' ', '\t', '\r', '\n');
        if (u.Length == 0)
        {
            return "";
        }
        var slash = u.LastIndexOf('\\');
        if (slash >= 0)
        {
            u = u[(slash + 1)..];
        }
        var at = u.IndexOf('@', StringComparison.Ordinal);
        if (at >= 0)
        {
            u = u[..at];
        }
        if (u.EndsWith('$'))
        {
            return "";
        }
        string[] bad = ["SYSTEM", "LOCAL SERVICE", "NETWORK SERVICE", "ANONYMOUS LOGON", "DWM-1", "DWM-2", "UMFD-0", "UMFD-1", "DEFAULTUSER0", "ADMINISTRATEUR", "ADMINISTRATOR"];
        return bad.Contains(u.ToUpperInvariant()) ? "" : u;
    }

    /// <summary>
    /// Date of one record (Domenia 1 ConvertTo-DomeniaInventoryWhen): ISO dates (an offset or « Z » wins, otherwise local time)
    /// and Unix seconds are read; « 08/10/2026 » is ambiguous and stays unread; a date in the future beyond the tolerance is
    /// ignored.
    /// </summary>
    public static RelationRecordWhen When(string? value, bool unixTime, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var text = (value ?? "").Trim();
        if (text.Length == 0)
        {
            return new RelationRecordWhen("", null, "");
        }
        DateTimeOffset? utc = null;
        if (unixTime)
        {
            if (UnixShortPattern().IsMatch(text) && long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds) && seconds > 0)
            {
                utc = DateTimeOffset.FromUnixTimeSeconds(seconds);
            }
        }
        else if (IsoPattern().IsMatch(text))
        {
            utc = RelationRules.ParseStoredWhen(text, zone);
        }
        if (utc is not DateTimeOffset at)
        {
            return new RelationRecordWhen(text, null, "");
        }
        if (at > now + FutureTolerance)
        {
            return new RelationRecordWhen("", null, "Date du fichier dans le futur (" + text + ")" + C + "ignorée, date de l’import retenue.");
        }
        return new RelationRecordWhen(at.UtcDateTime.ToString("o", CultureInfo.InvariantCulture), at, "");
    }

    /// <summary>
    /// Only the most recent records of each workstation reach the preview (Domenia 1 Select-DomeniaLatestInventoryRecords):
    /// equal dates are all kept (shown as a conflict); older records are counted, never silently lost.
    /// </summary>
    public static (ImmutableArray<RelationInventoryRecord> Records, int Dropped) Latest(IReadOnlyList<RelationInventoryRecord> records, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(records);
        var keys = new string[records.Count];
        var ticks = new long[records.Count];
        var competes = new bool[records.Count];
        var best = new Dictionary<string, long>(StringComparer.Ordinal);
        for (var i = 0; i < records.Count; i++)
        {
            keys[i] = RelationRules.ComputerKey(records[i].Computer);
            ticks[i] = When(records[i].When, records[i].UnixTime, now, zone).Utc?.UtcTicks ?? 0;
            competes[i] = keys[i].Length > 0 && records[i].User.Trim().Length > 0 && records[i].Reject.Length == 0;
            if (competes[i] && (!best.TryGetValue(keys[i], out var known) || ticks[i] > known))
            {
                best[keys[i]] = ticks[i];
            }
        }
        var kept = ImmutableArray.CreateBuilder<RelationInventoryRecord>();
        var dropped = 0;
        for (var i = 0; i < records.Count; i++)
        {
            if (!competes[i] || ticks[i] == best[keys[i]])
            {
                kept.Add(records[i]);
            }
            else
            {
                dropped++;
            }
        }
        return (kept.ToImmutable(), dropped);
    }

    /// <summary>
    /// Source priority inside one file, per workstation: the most recent dated record wins; the same account again is a
    /// duplicate; two accounts with no date to decide between them are a conflict and none is imported.
    /// </summary>
    public static ImmutableArray<RelationPriorityDecision> Priority(IReadOnlyList<(int Record, string ComputerKey, string UserKey, long Ticks)> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        var decisions = new RelationPriorityDecision[items.Count];
        var groups = new Dictionary<string, List<int>>(StringComparer.Ordinal);
        for (var i = 0; i < items.Count; i++)
        {
            decisions[i] = new RelationPriorityDecision("Retenue", "");
            if (items[i].ComputerKey.Length == 0 || items[i].UserKey.Length == 0)
            {
                continue;
            }
            if (!groups.TryGetValue(items[i].ComputerKey, out var list))
            {
                list = [];
                groups.Add(items[i].ComputerKey, list);
            }
            list.Add(i);
        }
        foreach (var members in groups.Values.Where(m => m.Count > 1))
        {
            var best = members.Max(i => items[i].Ticks);
            var top = members.Where(i => items[i].Ticks == best).ToList();
            var topUsers = top.Select(i => items[i].UserKey).Distinct(StringComparer.Ordinal).ToList();
            if (topUsers.Count > 1)
            {
                var names = string.Join(", ", topUsers);
                var why = best > 0 ? "même date" : "aucune date";
                foreach (var index in members)
                {
                    decisions[index] = top.Contains(index)
                        ? new RelationPriorityDecision("Conflit", "Conflit dans le fichier" + C + "le poste désigne " + names + " (" + why + " pour les départager). Aucune de ces lignes n’est importée.")
                        : new RelationPriorityDecision("Remplacée", "Poste présent ailleurs dans le fichier avec une date plus récente, en conflit" + C + "ligne non importée.");
                }
                continue;
            }
            var winner = top[0];
            foreach (var index in members.Where(i => i != winner))
            {
                var where = items[winner].Record < items[index].Record ? "plus haut" : "plus bas";
                decisions[index] = items[index].UserKey == items[winner].UserKey
                    ? new RelationPriorityDecision("Doublon", "Poste déjà présent " + where + " dans le fichier avec le même compte.")
                    : new RelationPriorityDecision("Remplacée", "Poste déjà présent " + where + " dans le fichier avec une date plus récente (compte " + items[winner].UserKey + ")" + C + "ligne non importée.");
            }
        }
        return [.. decisions];
    }

    // ------------------------------------------------------------------ rollback batch (point 138)

    /// <summary>Batch of one import: UTC time of the preview to the millisecond, then the first 8 hexadecimal digits of its identifier.</summary>
    public static string BatchId(string id, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(id);
        var hex = string.Concat(id.ToLowerInvariant().Where(Uri.IsHexDigit));
        if (hex.Length < 8)
        {
            hex += Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(id)));
        }
        return now.UtcDateTime.ToString("yyyyMMdd'T'HHmmssfff", CultureInfo.InvariantCulture) + "Z-" + hex[..8];
    }

    /// <summary>Instant of a batch identifier, or null when it is not one.</summary>
    public static DateTimeOffset? BatchInstant(string? batchId)
    {
        if (batchId is null || !BatchPattern().IsMatch(batchId))
        {
            return null;
        }
        return DateTimeOffset.TryParseExact(batchId[..18], "yyyyMMdd'T'HHmmssfff", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var at)
            ? at
            : null;
    }

    /// <summary>Batch identifier written at the start of the details of an imported association (Domenia 1 Get-DomeniaImportBatchToken).</summary>
    public static string? BatchToken(string? details)
    {
        var match = TokenPattern().Match(details ?? "");
        return match.Success ? match.Groups[1].Value : null;
    }

    // ------------------------------------------------------------------ statuses of the preview

    /// <summary>
    /// What the preview says about one row (Domenia 1 Get-DomeniaLinkImportStatus, point 138): Valide, Conflit, Rejet, Doublon,
    /// Déjà connue, Inconnue or Reportée. A workstation that already has an association with another account is never replaced.
    /// </summary>
    public static RelationImportStatus Status(string user, string computer, string? storedLogin, bool indexAvailable, bool userKnown, bool computerKnown,
        string unverified, int readyBefore, string rejected, string fileConflict, string fileSuperseded)
    {
        if (rejected.Length > 0)
        {
            return new("Rejetée", "Rejet", rejected, false, false);
        }
        if (user.Length == 0 || computer.Length == 0)
        {
            return new("Ignorée", "Rejet", "Utilisateur ou poste manquant ou illisible.", false, false);
        }
        if (fileConflict.Length > 0)
        {
            return new("Conflit", "Conflit", fileConflict, false, false);
        }
        if (fileSuperseded.Length > 0)
        {
            return new("Ignorée", "Doublon", fileSuperseded, false, false);
        }
        if (!string.IsNullOrEmpty(storedLogin))
        {
            return RelationRules.LoginKey(storedLogin) == RelationRules.LoginKey(user)
                ? new("Ignorée", "Déjà connue", "Association déjà connue.", false, false)
                : new("Conflit", "Conflit", "Poste déjà associé à " + storedLogin + C + "aucune association remplacée.", false, false);
        }
        if (indexAvailable && (!userKnown || !computerKnown))
        {
            var missing = !userKnown && !computerKnown ? "compte et poste absents" : !userKnown ? "compte absent" : "poste absent";
            return new("Inconnue", "Inconnue", "Inconnue dans l’annuaire" + C + missing + " de l’index local. Ligne non importée.", false, false);
        }
        if (readyBefore >= BatchLimit)
        {
            return new("Ignorée", "Reportée", "Au-delà de " + FrenchText.Integer(BatchLimit) + " associations par import" + C
                + "importez à nouveau le même fichier ensuite, les lignes déjà importées seront reconnues.", false, false);
        }
        if (!indexAvailable)
        {
            var why = unverified.Trim().Length == 0 ? "index local non lu" : unverified.Trim();
            return new("À importer", "Valide", "Présence dans Active Directory non vérifiée" + C + why + ".", true, false);
        }
        return new("À importer", "Valide", "Compte et poste connus de l’index local.", true, true);
    }

    /// <summary>
    /// An imported relation (Domenia 1 New-DomeniaImportedRelation): the Source of the adapter, never the source of the file;
    /// no score; only an ISO date of the file is kept, otherwise the import date; the details start with the batch.
    /// </summary>
    public static StoredRelation Imported(RelationImportAdapter adapter, string user, string computer, string fileName, int record, string fileSource, string fileDetails,
        RelationRecordWhen when, bool verified, RelationIndexEntry? userEntry, RelationIndexEntry? computerEntry, string batchId, string declarant, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(when);
        var note = when.Note.Length > 0 ? " " + when.Note : "";
        if (when.Utc is null && when.Text.Length > 0)
        {
            note = " Date du fichier non reconnue (" + when.Text + ")" + C + "date de l’import retenue." + note;
        }
        var details = "Lot d’import " + batchId + ". Importé depuis " + fileName;
        if (record > 0)
        {
            details += ", enregistrement " + record.ToString(CultureInfo.InvariantCulture);
        }
        details += "." + note;
        if (fileSource.Length > 0)
        {
            details += " Source indiquée dans le fichier" + C + fileSource + " (non reprise).";
        }
        if (fileDetails.Length > 0)
        {
            details += " " + fileDetails;
        }
        if (details.Length > 400)
        {
            details = details[..399] + "…";
        }
        return new StoredRelation(user, userEntry?.Guid, userEntry?.Dn, computer, computerEntry?.Guid, computerEntry?.Dn, RelationKind.Imported,
            Adapter(adapter).Source, when.Utc ?? WritePlans.TruncateToSecond(now), details, verified, declarant, batchId);
    }

    [GeneratedRegex(@"[\s_\-]+", RegexOptions.CultureInvariant)]
    private static partial Regex SeparatorPattern();

    [GeneratedRegex(@"^(?i)(system|local ?service|network ?service|localsystem|nt authority\\.*|(dwm|umfd)-\d+|login|reboot|runlevel|shutdown|\(unknown\))$", RegexOptions.CultureInvariant)]
    private static partial Regex NonPersonPattern();

    [GeneratedRegex(@"^[1-9]\d{8,10}$", RegexOptions.CultureInvariant)]
    private static partial Regex UnixPattern();

    [GeneratedRegex(@"^\d{1,11}$", RegexOptions.CultureInvariant)]
    private static partial Regex UnixShortPattern();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2}(\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?$", RegexOptions.CultureInvariant)]
    private static partial Regex IsoPattern();

    [GeneratedRegex(@"^\d{1,3}(\.\d{1,3}){3}$", RegexOptions.CultureInvariant)]
    private static partial Regex IpPattern();

    [GeneratedRegex(@"^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$", RegexOptions.CultureInvariant)]
    private static partial Regex UuidPattern();

    [GeneratedRegex(@"^\d{8}T\d{9}Z-[0-9a-f]{8}$", RegexOptions.CultureInvariant)]
    private static partial Regex BatchPattern();

    [GeneratedRegex(@"^Lot d’import (\d{8}T\d{9}Z-[0-9a-f]{8})\.", RegexOptions.CultureInvariant)]
    private static partial Regex TokenPattern();
}
