using System.Collections.Immutable;
using System.Xml;

namespace Domenia.Core;

/// <summary>
/// Controllers of the domain (AUD-004 to AUD-008; Domenia 1 Get-DomeniaAdHealthView, Get-DomeniaDcServiceView,
/// ConvertFrom-DomeniaReplNeighbor, ConvertFrom-DomeniaReplMetadata, Compare-DomeniaDcReadings). An unreachable controller is
/// « not read », never « down »; a refused replication read is not a replication fault; local USNs are never compared. Pure.
/// </summary>
public static class AuditControllerRules
{
    public const int MaxSkewSeconds = 300;
    public const int MaxReplicationHours = 24;
    public const int MaxControllers = 10;

    private static readonly string[] CoreServices = ["NTDS", "Netlogon", "Kdc", "W32Time", "ADWS"];
    private static readonly string[] ServiceOrder = ["NTDS", "Netlogon", "Kdc", "W32Time", "ADWS", "DNS", "DFSR", "NtFrs"];

    public static AuditControllerList ListView(ControllerListRead read)
    {
        ArgumentNullException.ThrowIfNull(read);
        var rows = read.Controllers.Select(dc =>
        {
            var name = string.IsNullOrEmpty(dc.DnsHostName) ? dc.Name : dc.DnsHostName;
            var pdc = !string.IsNullOrEmpty(read.Pdc) && string.Equals(name, read.Pdc, StringComparison.OrdinalIgnoreCase);
            var roles = ImmutableArray.CreateBuilder<string>();
            if (pdc)
            {
                roles.Add("Émulateur PDC");
            }
            if (dc.ReadOnly)
            {
                roles.Add("Lecture seule (RODC)");
            }
            return new AuditControllerRow(name, dc.Name, dc.Site, dc.OperatingSystem, roles.ToImmutable(), pdc, dc.ReadOnly, dc.Dn);
        }).ToImmutableArray();
        var text = FrenchText.Count(rows.Length, "contrôleur lu", "contrôleurs lus");
        if (read.Truncated)
        {
            text += " (liste bornée à 100)";
        }
        if (!string.IsNullOrEmpty(read.Pdc))
        {
            text += ", émulateur PDC : " + read.Pdc;
        }
        else if (!string.IsNullOrEmpty(read.PdcError))
        {
            text += ", émulateur PDC non lu";
        }
        text += ". Choisissez-en jusqu’à 10, puis lancez le diagnostic.";
        return new AuditControllerList(rows, read.Pdc, read.Truncated, text, read.ReadAt);
    }

    /// <summary>Validated, distinct controller names: 1 to 10 DNS names, never anything else (audit.controllersInvalid).</summary>
    public static ImmutableArray<string> RequireControllers(IEnumerable<string> names)
    {
        ArgumentNullException.ThrowIfNull(names);
        var list = names.Select(n => n.Trim()).Where(n => n.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToImmutableArray();
        if (list.Length == 0)
        {
            throw new DomeniaOperationException(AuditErrors.ControllersInvalid, "Choisissez au moins un contrôleur dans la liste.");
        }
        if (list.Length > MaxControllers)
        {
            throw new DomeniaOperationException(AuditErrors.ControllersInvalid, "Diagnostic borné à 10 contrôleurs : " + FrenchText.Integer(list.Length) + " sont choisis.");
        }
        if (list.Any(n => !IsHostName(n)))
        {
            throw new DomeniaOperationException(AuditErrors.ControllersInvalid, "Nom de contrôleur invalide : aucune lecture.");
        }
        return list;
    }

    /// <summary>
    /// Every chosen name must be a controller of the last list of the domain (DNS name, or short name when unique); the
    /// names come back as the list writes them. A host outside the list is never contacted (audit.controllersInvalid).
    /// </summary>
    public static ImmutableArray<string> RequireKnown(IReadOnlyList<string> chosen, ControllerListRead list)
    {
        ArgumentNullException.ThrowIfNull(chosen);
        ArgumentNullException.ThrowIfNull(list);
        var result = ImmutableArray.CreateBuilder<string>(chosen.Count);
        foreach (var name in chosen)
        {
            var match = list.Controllers.FirstOrDefault(c => string.Equals(c.DnsHostName, name, StringComparison.OrdinalIgnoreCase))
                ?? (list.Controllers.Count(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase)) == 1
                    ? list.Controllers.First(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase)) : null);
            if (match is null)
            {
                throw new DomeniaOperationException(AuditErrors.ControllersInvalid,
                    FrenchText.Quote(name.Length > 80 ? name[..80] + "…" : name) + " n’est pas un contrôleur de la liste du domaine : aucune lecture. Relisez la liste des contrôleurs.");
            }
            var canonical = string.IsNullOrEmpty(match.DnsHostName) ? match.Name : match.DnsHostName;
            if (!result.Contains(canonical, StringComparer.OrdinalIgnoreCase))
            {
                result.Add(canonical);
            }
        }
        return result.ToImmutable();
    }

    /// <summary>« ^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$ », as the probes of Domenia 1.</summary>
    public static bool IsHostName(string name) =>
        name.Length is > 0 and <= 254 && char.IsAsciiLetterOrDigit(name[0]) && name.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-');

    public static AuditHealth HealthView(ControllerProbesRead probe, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(probe);
        ArgumentNullException.ThrowIfNull(zone);
        var srv = new HashSet<string>(probe.SrvRecords.Select(s => s.Trim().TrimEnd('.')), StringComparer.OrdinalIgnoreCase);
        var probed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var rows = ImmutableArray.CreateBuilder<AuditHealthRow>();
        var neighbors = ImmutableArray.CreateBuilder<AuditNeighborRow>();
        var skews = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
        foreach (var result in probe.Results)
        {
            var dc = result.Controller;
            probed.Add(dc);
            var reasons = new List<string>();
            var notRead = false;
            static string YesNo(bool? v) => v switch { true => "oui", false => "non", _ => "non testé" };
            var reach = "LDAP 389 : " + YesNo(result.Ldap) + " · Kerberos 88 : " + YesNo(result.Kerberos);
            if (result.Ldap != true)
            {
                notRead = true;
                reasons.Add("Injoignable en LDAP depuis ce poste : aucune conclusion sur son état.");
            }
            else if (result.Kerberos == false)
            {
                reasons.Add("Port Kerberos 88 fermé depuis ce poste.");
            }
            var dns = "Non vérifié";
            if (probe.SrvState == ReadState.Read)
            {
                if (srv.Contains(dc))
                {
                    dns = "Présent dans les enregistrements SRV";
                }
                else
                {
                    dns = "Absent des enregistrements SRV";
                    reasons.Add("Absent des enregistrements SRV _ldap._tcp.dc._msdcs : les postes ne le trouvent pas par DNS.");
                }
            }
            if (result.Addresses.Length > 0)
            {
                dns += " · " + string.Join(", ", result.Addresses);
            }
            else if (!string.IsNullOrEmpty(result.DnsError))
            {
                dns += " · nom non résolu";
                reasons.Add("Nom DNS du contrôleur non résolu depuis ce poste.");
            }
            var time = "Non lue";
            var sync = "Non lu";
            var replication = "Non lue";
            long? failureSum = null;
            double? skew = null;
            switch (result.RootDse)
            {
                case ReadState.Read:
                    if (result.CurrentTime is DateTimeOffset dcTime && result.LocalTime is DateTimeOffset localTime)
                    {
                        var seconds = (dcTime - localTime).TotalSeconds;
                        skew = Math.Round(seconds, 1);
                        skews[dc] = seconds;
                        time = (seconds < 0 ? FrenchText.Minus : "+") + FrenchText.Integer((long)Math.Round(Math.Abs(seconds))) + FrenchText.Nbsp + "s par rapport à ce poste";
                        if (Math.Abs(seconds) > MaxSkewSeconds)
                        {
                            reasons.Add("Écart d’heure supérieur à " + FrenchText.Integer(MaxSkewSeconds) + FrenchText.Nbsp + "s avec ce poste : risque d’échec Kerberos (à confirmer, l’horloge de ce poste peut aussi dériver).");
                        }
                    }
                    if (result.IsSynchronized == true)
                    {
                        sync = "Oui";
                    }
                    else if (result.IsSynchronized == false)
                    {
                        sync = "Non";
                        reasons.Add("Annuaire non synchronisé (isSynchronized faux) : le contrôleur n’a pas terminé sa réplication initiale.");
                    }
                    switch (result.Replication)
                    {
                        case ReadState.Read:
                            var failing = 0;
                            var stale = 0;
                            long sum = 0;
                            DateTimeOffset? oldest = null;
                            foreach (var n in result.Neighbors)
                            {
                                if (n.ConsecutiveFailures > 0)
                                {
                                    failing++;
                                    sum += n.ConsecutiveFailures;
                                }
                                var isStale = n.Never || (n.LastSuccess is DateTimeOffset s && (now - s).TotalHours > MaxReplicationHours);
                                if (isStale)
                                {
                                    stale++;
                                }
                                if (n.LastSuccess is DateTimeOffset success && (oldest is null || success < oldest))
                                {
                                    oldest = success;
                                }
                                neighbors.Add(new AuditNeighborRow(
                                    dc,
                                    n.Partner,
                                    n.NamingContext,
                                    n.LastSuccess,
                                    n.Never ? "Jamais" : n.LastSuccess is DateTimeOffset ls ? AuditText.LocalDateTime(ls, zone) : "Non lu",
                                    n.LastAttempt,
                                    n.LastAttempt is DateTimeOffset la ? AuditText.LocalDateTime(la, zone) : "Non lue",
                                    AuditText.ReplicationResult(n.LastResult),
                                    n.ConsecutiveFailures,
                                    n.Never,
                                    n.ConsecutiveFailures > 0 || isStale ? Tone.Warn : Tone.Ok));
                            }
                            replication = FrenchText.Count(result.Neighbors.Length, "lien entrant", "liens entrants");
                            if (oldest is DateTimeOffset old)
                            {
                                replication += ", plus ancien succès il y a " + AuditText.Duration(now - old);
                            }
                            failureSum = sum;
                            if (failing > 0)
                            {
                                reasons.Add(FrenchText.Count(failing, "lien de réplication en échec répété", "liens de réplication en échec répété") + ".");
                            }
                            if (stale > 0)
                            {
                                reasons.Add(FrenchText.Count(stale, "lien", "liens") + " sans succès depuis plus de " + FrenchText.Integer(MaxReplicationHours) + FrenchText.Nbsp + "h.");
                            }
                            break;
                        case ReadState.Empty:
                            replication = "Aucun partenaire renvoyé (contrôleur unique, ou lecture non autorisée)";
                            break;
                        case ReadState.Refused or ReadState.Unavailable:
                            replication = "Lecture refusée ou impossible : " + result.ReplicationError;
                            break;
                    }
                    break;
                case ReadState.Refused:
                    notRead = true;
                    reasons.Add("Lecture du RootDSE refusée.");
                    break;
                default:
                    if (result.Ldap == true)
                    {
                        notRead = true;
                        reasons.Add("RootDSE illisible : " + result.RootDseError);
                    }
                    break;
            }
            var verdict = notRead ? ControllerVerdict.NotRead : reasons.Count > 0 ? ControllerVerdict.Check : ControllerVerdict.Clear;
            var (label, tone) = verdict switch
            {
                ControllerVerdict.Clear => ("Sans écart constaté", Tone.Ok),
                ControllerVerdict.Check => ("À vérifier", Tone.Warn),
                _ => ("Non lu", Tone.Off),
            };
            rows.Add(new AuditHealthRow(dc, verdict, label, tone, result.Ldap, result.Kerberos, reach, time, skew, sync, replication, failureSum, dns, [.. reasons], string.Join(" ", reasons)));
        }

        var facts = ImmutableArray.CreateBuilder<AuditFact>();
        if (!string.IsNullOrEmpty(probe.Pdc) && skews.TryGetValue(probe.Pdc, out var pdcSkew))
        {
            foreach (var row in rows)
            {
                if (string.Equals(row.Controller, probe.Pdc, StringComparison.OrdinalIgnoreCase) || !skews.TryGetValue(row.Controller, out var s))
                {
                    continue;
                }
                var delta = s - pdcSkew;
                if (Math.Abs(delta) > MaxSkewSeconds)
                {
                    facts.Add(AuditPolicyRules.Fact("Écart avec l’émulateur PDC · " + row.Controller, FrenchText.Integer((long)Math.Round(delta)) + FrenchText.Nbsp + "s",
                        FactState.Estimated, "currentTime des RootDSE", "Calculé à travers l’horloge de ce poste, à quelques secondes près."));
                }
            }
        }
        switch (probe.SrvState)
        {
            case ReadState.Read:
                var extra = srv.Where(n => !probed.Contains(n)).Order(StringComparer.OrdinalIgnoreCase).ToList();
                facts.Add(AuditPolicyRules.Fact("Enregistrements SRV des contrôleurs",
                    FrenchText.Count(srv.Count, "nom", "noms") + (extra.Count > 0 ? " dont non diagnostiqués : " + string.Join(", ", extra) : string.Empty),
                    FactState.Observed, "_ldap._tcp.dc._msdcs", "Résolution faite depuis ce poste, avec son serveur DNS."));
                break;
            case ReadState.Refused or ReadState.Unavailable:
                facts.Add(AuditPolicyRules.Fact("Enregistrements SRV des contrôleurs", "Lecture impossible", FactState.Unavailable, "DNS", probe.SrvError));
                break;
            default:
                facts.Add(AuditPolicyRules.Fact("Enregistrements SRV des contrôleurs", "Non vérifiés", FactState.Unknown, "DNS", "Nom DNS du domaine inconnu."));
                break;
        }
        var all = rows.ToImmutable();
        var summary = FrenchText.Count(all.Length, "contrôleur diagnostiqué", "contrôleurs diagnostiqués") + " : "
            + FrenchText.Integer(all.Count(r => r.Verdict == ControllerVerdict.Clear)) + " sans écart, "
            + FrenchText.Integer(all.Count(r => r.Verdict == ControllerVerdict.Check)) + " à vérifier, "
            + FrenchText.Integer(all.Count(r => r.Verdict == ControllerVerdict.NotRead)) + " non lu"
            + (all.Count(r => r.Verdict == ControllerVerdict.NotRead) > 1 ? "s" : string.Empty)
            + ". Sondes sans droit d’administration : aucune commande sur les contrôleurs.";
        return new AuditHealth(all, neighbors.ToImmutable(), facts.ToImmutable(), summary, probe.ReadAt);
    }

    public static AuditServices ServicesView(ControllerServicesReads read)
    {
        ArgumentNullException.ThrowIfNull(read);
        var rows = ImmutableArray.CreateBuilder<AuditServiceRow>();
        foreach (var result in read.Results)
        {
            if (result.State != ReadState.Read)
            {
                var text = result.State switch
                {
                    ReadState.Refused => "Lecture refusée : droits d’administration du contrôleur requis",
                    ReadState.NotRead => "Non interrogé",
                    _ => "Lecture impossible",
                };
                rows.Add(new AuditServiceRow(result.Controller, null, text, string.Empty, result.Message ?? string.Empty, result.State == ReadState.Refused ? Tone.Warn : Tone.Off));
                continue;
            }
            var services = result.Services.GroupBy(s => s.Name, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
            foreach (var name in ServiceOrder)
            {
                services.TryGetValue(name, out var service);
                var running = service is not null && service.State == "Running";
                string finding;
                Tone tone;
                if (CoreServices.Contains(name))
                {
                    (finding, tone) = service is null ? ("Absent : à vérifier", Tone.Warn) : running ? ("Conforme", Tone.Ok) : ("Non démarré : à vérifier", Tone.Warn);
                }
                else if (name == "DNS")
                {
                    (finding, tone) = service is null ? ("Absent : normal si le DNS est hébergé ailleurs", Tone.Info) : running ? ("Conforme", Tone.Ok) : ("Non démarré : à vérifier", Tone.Warn);
                }
                else
                {
                    var other = name == "NtFrs" ? "DFSR" : "NtFrs";
                    var otherRunning = services.TryGetValue(other, out var o) && o.State == "Running";
                    (finding, tone) = running ? ("Conforme (réplication de SYSVOL)", Tone.Ok)
                        : otherRunning ? ("Non utilisé : " + other + " réplique SYSVOL", Tone.Off)
                        : ("Aucun service de réplication de SYSVOL en cours : à vérifier", Tone.Warn);
                }
                var state = service is null ? "Absent" : service.State switch { "Running" => "En cours", "Stopped" => "Arrêté", var s => s };
                var start = service?.StartMode switch { "Auto" => "Automatique", "Manual" => "Manuel", "Disabled" => "Désactivé", var s => s ?? string.Empty };
                rows.Add(new AuditServiceRow(result.Controller, name, state, start, finding, tone));
            }
        }
        var skipped = read.Results.Count(r => r.State == ReadState.NotRead);
        var summary = "Services lus. Un refus signale un manque de droits, pas un service arrêté.";
        if (skipped > 0)
        {
            summary += " " + FrenchText.Count(skipped, "contrôleur non interrogé", "contrôleurs non interrogés") + " : temps de lecture épuisé.";
        }
        return new AuditServices(rows.ToImmutable(), skipped, read.BudgetSeconds, summary, read.ReadAt);
    }

    /// <summary>Time budget of the privileged services read: 60 s + 25 s per controller, 300 s at most; the worker keeps 20 s below it.</summary>
    public static int ServicesBudgetSeconds(int controllers) => Math.Min(300, 60 + (25 * controllers)) - 20;

    public static AuditComparison ComparisonView(ObjectComparisonRead read, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(read);
        ArgumentNullException.ThrowIfNull(zone);
        var reached = read.Readings.Where(r => r.Reachable).ToList();
        var names = reached.SelectMany(r => r.Attributes.Keys).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToList();
        var rows = ImmutableArray.CreateBuilder<AuditComparisonRow>();
        foreach (var attribute in names)
        {
            var cells = ImmutableArray.CreateBuilder<AuditComparisonCell>();
            var values = new List<string>();
            foreach (var reading in reached)
            {
                var value = reading.Attributes.TryGetValue(attribute, out var v) ? string.Join(" | ", v.Order(StringComparer.Ordinal)) : string.Empty;
                var meta = reading.Metadata.FirstOrDefault(m => string.Equals(m.Attribute, attribute, StringComparison.OrdinalIgnoreCase));
                cells.Add(new AuditComparisonCell(reading.Controller, value, meta?.Version, meta?.ChangedAt, meta?.OriginatingController));
                values.Add(value);
            }
            rows.Add(new AuditComparisonRow(attribute, values.Distinct(StringComparer.Ordinal).Count() <= 1, cells.ToImmutable()));
        }
        var all = rows.ToImmutable();
        var notRead = read.Readings.Where(r => !r.Reachable).Select(r => r.Controller + " : " + (r.Error ?? "non lu")).ToImmutableArray();
        var differences = all.Count(r => !r.Identical);
        var comparable = reached.Count >= 2;
        var summary = !comparable
            ? "Comparaison impossible : il faut au moins deux contrôleurs lus."
            : differences == 0
                ? "Aucune différence entre " + FrenchText.Count(reached.Count, "contrôleur", "contrôleurs") + " sur " + FrenchText.Count(all.Length, "attribut", "attributs") + "."
                : FrenchText.Count(differences, "attribut diffère", "attributs diffèrent") + " entre les contrôleurs : réplication en cours ou en retard, voyez les dates d’origine.";
        return new AuditComparison(read.Dn, read.Name, [.. read.Readings.Select(r => r.Controller)], all, differences, comparable, notRead,
            "Les USN sont locaux à chaque contrôleur : ils ne constituent pas une horloge commune. Les dates sont celles de la dernière modification d’origine.",
            summary, read.ReadAt);
    }

    /// <summary>
    /// Parses one DS_REPL_NEIGHBOR fragment (msDS-ReplAllInboundNeighbors); null when unreadable. A DTD is refused outright and
    /// no external entity is ever resolved. A last success in 1601 means « never ».
    /// </summary>
    public static ReplicationNeighborRead? ParseNeighbor(string? xml)
    {
        if (string.IsNullOrWhiteSpace(xml))
        {
            return null;
        }
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null };
        var document = new XmlDocument { XmlResolver = null };
        try
        {
            using var text = new StringReader(xml.Trim('\0'));
            using var reader = XmlReader.Create(text, settings);
            document.Load(reader);
        }
        catch (XmlException)
        {
            return null;
        }
        var node = document.DocumentElement;
        if (node is null || node.Name != "DS_REPL_NEIGHBOR")
        {
            return null;
        }
        string Get(string name) => node.SelectSingleNode(name)?.InnerText ?? string.Empty;
        var sourceDn = Get("pszSourceDsaDN");
        var partner = string.Empty;
        const string Marker = "CN=NTDS Settings,CN=";
        var at = sourceDn.IndexOf(Marker, StringComparison.OrdinalIgnoreCase);
        if (at >= 0)
        {
            var rest = sourceDn[(at + Marker.Length)..];
            var comma = rest.IndexOf(',', StringComparison.Ordinal);
            partner = comma > 0 ? rest[..comma] : rest;
        }
        static DateTimeOffset? Date(string text) =>
            DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal, out var d) ? d : null;
        var success = Date(Get("ftimeLastSyncSuccess"));
        var attempt = Date(Get("ftimeLastSyncAttempt"));
        var never = success is null || success.Value.Year <= 1601;
        _ = long.TryParse(Get("dwLastSyncResult"), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var result);
        _ = long.TryParse(Get("cNumConsecutiveSyncFailures"), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var failures);
        return new ReplicationNeighborRead(Get("pszNamingContext"), partner, never ? null : success, attempt is DateTimeOffset a && a.Year > 1601 ? a : null, result, failures, never);
    }
}
