using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    public async Task<RelationImportPreview> ImportPreviewAsync(RelationImportRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!Enum.IsDefined(request.Adapter) || request.Id.Length is < 1 or > 128 || request.Id.Any(char.IsControl)
            || request.FileName.Length is < 1 or > 255 || request.FileName.Any(char.IsControl))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Identifiant, format ou nom du fichier invalide."); }
        var adapter = RelationImport.Adapter(request.Adapter);
        if (request.Text.Length > adapter.MaxCharacters)
        { throw new DomeniaOperationException(RelationErrors.ImportTooLarge, "Fichier trop volumineux ; découpez le fichier ou filtrez l’export."); }
        var local = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false);
        if (local.Stored.Truncated || local.Stored.Rejected > 0)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Base partiellement lisible ; les conflits d’import ne peuvent pas être établis."); }
        var now = source.Clock.GetUtcNow(); var notes = new List<string>();
        IReadOnlyList<RelationInventoryRecord> records; int total;
        if (request.Adapter == RelationImportAdapter.Osquery)
        {
            var parsed = RelationImport.ParseOsquery(request.Text);
            if (parsed.Format.Length == 0) { throw new DomeniaOperationException(RelationErrors.ImportEmpty, RelationErrors.ImportEmptyMessage); }
            // Normalise trusted dates before selecting the latest osquery record; an invalid future date must not beat a real reading.
            var dated = parsed.Records.Select(r =>
            {
                var date = ImportWhen(r, now);
                return r with { When = date.Utc?.ToString("o") ?? "", UnixTime = false,
                    Details = r.Details + (date.Note.Length > 0 ? " " + date.Note : date.Utc is null && date.Text.Length > 0 ? " Date du fichier non reconnue ; date de l’import retenue." : "") };
            }).ToArray();
            var latest = RelationImport.Latest(dated, now, source.Zone); records = latest.Records; total = records.Count;
            if (parsed.Rejected > 0) { notes.Add(FrenchText.Count(parsed.Rejected, "ligne JSON illisible écartée", "lignes JSON illisibles écartées") + "."); }
            if (parsed.Skipped > 0) { notes.Add(FrenchText.Count(parsed.Skipped, "session sans compte ignorée", "sessions sans compte ignorées") + "."); }
            if (latest.Dropped > 0) { notes.Add(FrenchText.Count(latest.Dropped, "relevé plus ancien écarté", "relevés plus anciens écartés") + "."); }
            if (parsed.Truncated) { notes.Add("Lecture arrêtée à 20 000 enregistrements."); }
        }
        else
        {
            var csv = RelationImport.ParseCsv(request.Text); total = csv.Total;
            records = csv.Rows.Take(RelationImport.PreviewRecords).Select((row, i) => request.Adapter == RelationImportAdapter.Glpi
                ? RelationImport.GlpiRow(row, i + 1) : RelationImport.CsvRow(row, i + 1)).ToArray();
            if (csv.Truncated) { notes.Add("Lecture arrêtée à 20 000 enregistrements."); }
        }
        if (records.Count == 0) { throw new DomeniaOperationException(RelationErrors.ImportEmpty, RelationErrors.ImportEmptyMessage); }
        var prepared = records.Take(RelationImport.PreviewRecords).Select(record =>
        {
            var reject = record.Reject;
            if (record.User.Length > 320 || record.Computer.Length > 255 || record.User.Any(char.IsControl) || record.Computer.Any(char.IsControl))
            { reject = "Identité trop longue ou contenant un caractère de contrôle."; }
            if (reject.Length == 0) { reject = RelationImport.Identity(record.User, record.Computer, local.Directory.Domain.DnsName, local.Directory.Domain.NetbiosName); }
            var userName = reject.Length == 0 ? RelationImport.NormalizeUser(record.User) : "";
            var computerName = reject.Length == 0 ? RelationImport.NormalizeComputer(record.Computer) : "";
            // Resolve the complete qualified identity before using canonical SAM/Windows names: a UPN prefix is not a SAM.
            var user = userName.Length == 0 ? null : local.Lookup.User(null, record.User.Trim().Trim('"'));
            var computer = computerName.Length == 0 ? null : local.Lookup.Computer(null, record.Computer.Trim().Trim('"').TrimEnd('.'));
            var when = ImportWhen(record, now);
            return (Record: record, User: user, Computer: computer, UserName: user?.Login ?? userName, ComputerName: computer?.Name ?? computerName, Reject: reject, When: when);
        }).ToArray();
        var decisions = RelationImport.Priority(prepared.Select(p => (p.Record.Record,
            p.Computer?.Guid.ToString("D") ?? RelationRules.ComputerKey(p.ComputerName),
            p.User?.Guid.ToString("D") ?? RelationRules.LoginKey(p.UserName), p.When.Utc?.UtcTicks ?? 0L)).ToArray());
        var stored = local.Stored.Rows.Select(r => r.Relation).ToArray(); var batch = RelationImport.BatchId(request.Id, now);
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false); EnsureEpoch(local.Epoch);
        var rows = ImmutableArray.CreateBuilder<RelationImportRow>(); var importable = ImmutableArray.CreateBuilder<StoredRelation>();
        for (var i = 0; i < prepared.Length; i++)
        {
            cancellationToken.ThrowIfCancellationRequested(); var p = prepared[i]; var decision = decisions[i];
            var linked = stored.Where(r => RelationImport.SameComputer(r, p.Computer?.Guid, p.ComputerName)).ToArray();
            var known = linked.FirstOrDefault(r => p.User is not null && (r.UserGuid is { } id ? id == p.User.Guid : RelationRules.LoginKey(r.UserLogin) == RelationRules.LoginKey(p.UserName)));
            // A re-created account with the same login must not be labelled as an already known association.
            var storedLogin = known is not null ? p.UserName : linked.Length > 0 ? "une autre identité (« " + linked[0].UserLogin + " »)" : null;
            var status = RelationImport.Status(p.UserName, p.ComputerName, storedLogin, true, p.User is not null, p.Computer is not null, "", importable.Count,
                p.Reject, decision.Kind == "Conflit" ? decision.Reason : "", decision.Kind is "Doublon" or "Remplacée" ? decision.Reason : "");
            if (status.Import)
            {
                importable.Add(RelationImport.Imported(request.Adapter, p.UserName, p.ComputerName, request.FileName, p.Record.Record, p.Record.FileSource, p.Record.Details,
                    p.When, true, new(p.User!.Guid, p.User.Dn, p.User.Login), new(p.Computer!.Guid, p.Computer.Dn, p.Computer.Name), batch, session.Account.Login, now));
            }
            rows.Add(new(p.Record.Record, p.UserName.Length > 0 ? p.UserName : RelationRules.Flat(p.Record.User, 320),
                p.ComputerName.Length > 0 ? p.ComputerName : RelationRules.Flat(p.Record.Computer, 255), status.Status, status.Category, status.Reason, status.Import));
        }
        var all = rows.ToImmutable(); int Count(string category) => all.Count(r => r.Category == category);
        var counts = new RelationImportCounts(Count("Valide"), Count("Conflit"), Count("Rejet"), Count("Doublon"), Count("Déjà connue"), Count("Inconnue"), Count("Reportée"));
        notes.Add(local.Notice); notes.Add("Présence dans l’index local uniquement ; aucune vérification réseau actuelle. Les noms absents ou ambigus ne sont pas importés.");
        if (!local.Directory.Complete) { notes.Add("Index local incomplet : les identités absentes ne prouvent pas une absence dans AD."); }
        var summary = FrenchText.Count(importable.Count, "association à importer", "associations à importer") + " depuis " + request.FileName + ". Source imposée : " + adapter.Source
            + ". Aucun poste déjà associé n’est remplacé. Lot de retour arrière : " + batch + ".";
        if (total > all.Length) { summary += " Aperçu limité à " + FrenchText.Integer(all.Length) + " enregistrements sur " + FrenchText.Integer(total) + "."; }
        if (counts.Deferred > 0) { summary += " " + FrenchText.Count(counts.Deferred, "ligne reportée", "lignes reportées") + " au-delà de 64 associations par confirmation."; }
        EnsureEpoch(local.Epoch);
        return AdRelationResults.For(source).Remember(id => new AdRelationImportPreview(new(id, batch, request.Adapter, adapter.Label, adapter.Source, request.FileName,
            total, all.Length, importable.Count, counts, "verified", [.. notes], summary, all), importable.ToImmutable(), local.Stored.StoreId), local.Epoch).Preview;
    }

    private RelationRecordWhen ImportWhen(RelationInventoryRecord record, DateTimeOffset now)
    {
        var when = RelationImport.When(record.When, record.UnixTime, now, source.Zone);
        return when.Utc > now.AddMinutes(2) ? new("", null, "Date future écartée ; date de l’import retenue.") : when;
    }
}
