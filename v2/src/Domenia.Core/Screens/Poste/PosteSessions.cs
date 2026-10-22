using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>One session as the page lists it: readable account, protocol, state, local opening time, idle time.</summary>
public sealed record SessionRow(string Session, string User, string? Login, string State, string Protocol, string Opened, string Idle, string? ClientName, bool AccountUnread);

/// <summary>
/// Honest view of the sessions of a workstation (Domenia 1 ConvertTo-DomeniaSessionView): lines without account are counted,
/// not listed; a refused or partial read never proves that no session is open; consultation only.
/// </summary>
public sealed record SessionsResult(
    string Computer,
    DateTimeOffset? ReadAt,
    FactState ReadState,
    bool Partial,
    ImmutableArray<SessionRow> Rows,
    int UserSessions,
    int UnreadSessions,
    int SystemSessions,
    string? ConsoleUser,
    int RdpSessions,
    int DisconnectedSessions,
    string EmptyText,
    string StatusText,
    string Reader);

/// <summary>What the restart panel says of the sessions read just before (Domenia 1 Get-DomeniaRestartSessionSummary).</summary>
public sealed record RestartSessions(bool Known, int Count, ImmutableArray<string> Lines, string Text);

/// <summary>Rules of the Windows sessions (Domenia 1 D072, UX-39, SE-08). Pure: the reference time is a parameter.</summary>
public static class PosteSessions
{
    /// <summary>« 12 min » from an idle duration; empty when the workstation does not give this clock (nothing invented).</summary>
    public static string IdleText(TimeSpan? idle)
    {
        if (idle is not TimeSpan span || span <= TimeSpan.Zero)
        {
            return "";
        }
        var seconds = (long)span.TotalSeconds;
        return seconds < 1 ? "< 1 s"
            : seconds < 60 ? seconds.ToString(CultureInfo.InvariantCulture) + " s"
            : seconds < 3600 ? (seconds / 60).ToString(CultureInfo.InvariantCulture) + " min"
            : seconds < 86400 ? (seconds / 3600).ToString(CultureInfo.InvariantCulture) + " h"
            : (seconds / 86400).ToString(CultureInfo.InvariantCulture) + " j";
    }

    /// <summary>« Ouverte à » in local time: « 08:12 » the same day as the reading, « 20/10 18:40 » otherwise.</summary>
    public static string OpenedText(DateTimeOffset? logon, DateTimeOffset reference, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        if (logon is not DateTimeOffset at)
        {
            return "";
        }
        var local = TimeZoneInfo.ConvertTime(at, zone);
        var day = TimeZoneInfo.ConvertTime(reference, zone).Date;
        return local.Date == day ? local.ToString("HH':'mm", CultureInfo.InvariantCulture) : local.ToString("dd'/'MM HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>sAMAccountName of a session line (domain removed); empty for a line without account.</summary>
    public static string AccountName(string? user)
    {
        var account = (user ?? "").Trim();
        if (account.Length == 0 || account == "Compte non lu")
        {
            return "";
        }
        var slash = account.LastIndexOf('\\');
        return slash >= 0 ? account[(slash + 1)..].Trim() : account;
    }

    public static SessionsResult View(string computer, SourceStatus status, IReadOnlyList<LocalSession>? sessions, DateTimeOffset? readAt, string reader, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var partial = status == SourceStatus.Partial;
        var state = status switch
        {
            SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial => FactState.Observed,
            SourceStatus.Refused => FactState.Refused,
            SourceStatus.Unreachable or SourceStatus.Unavailable or SourceStatus.Error => FactState.Unavailable,
            _ => FactState.Unknown,
        };
        var incomplete = false;
        if (state == FactState.Observed && sessions is null)
        {
            state = FactState.Unknown;
            partial = false;
            incomplete = true;
        }
        var rows = ImmutableArray.CreateBuilder<SessionRow>();
        int system = 0, unread = 0, rdp = 0, disconnected = 0;
        string? consoleUser = null;
        if (state == FactState.Observed)
        {
            foreach (var s in sessions!)
            {
                var label = s.Id + (string.IsNullOrEmpty(s.Station) ? "" : " (" + s.Station + ")");
                var opened = OpenedText(s.LogonAt, readAt ?? DateTimeOffset.MinValue, zone);
                var idle = IdleText(s.Idle);
                if (string.IsNullOrWhiteSpace(s.User))
                {
                    if (s.State.Contains("partiel", StringComparison.OrdinalIgnoreCase))
                    {
                        unread++;
                        rows.Add(new SessionRow(label, "Compte non lu", null, s.State, s.Protocol, opened, idle, s.ClientName, true));
                        continue;
                    }
                    system++;
                    continue;
                }
                var account = string.IsNullOrWhiteSpace(s.Domain) ? s.User! : s.Domain + "\\" + s.User;
                if (s.Protocol.Equals("Console", StringComparison.OrdinalIgnoreCase) && consoleUser is null)
                {
                    consoleUser = account;
                }
                if (s.Protocol.Equals("RDP", StringComparison.OrdinalIgnoreCase))
                {
                    rdp++;
                }
                if (s.State.StartsWith("Déconnect", StringComparison.OrdinalIgnoreCase) || s.State.StartsWith("Disconnect", StringComparison.OrdinalIgnoreCase))
                {
                    disconnected++;
                }
                rows.Add(new SessionRow(label, account, s.User, s.State, s.Protocol, opened, idle, s.ClientName, false));
            }
        }
        var users = rows.Count - unread;
        var empty = EmptyText(status, incomplete, users, rdp, consoleUser is not null, unread);
        var parts = new List<string>();
        if (readAt is DateTimeOffset at)
        {
            parts.Add("Lu à " + PosteText.LocalDateTime(at, zone));
        }
        if (state == FactState.Observed)
        {
            var segments = new List<string>();
            if (users > 0)
            {
                segments.Add(FrenchText.Count(users, "session avec compte", "sessions avec compte"));
            }
            if (unread > 0)
            {
                segments.Add(FrenchText.Integer(unread) + " dont le compte n’a pas pu être lu");
            }
            if (system > 0)
            {
                segments.Add(FrenchText.Count(system, "ligne sans compte masquée", "lignes sans compte masquées") + " : services, écran de connexion, écouteur RDP");
            }
            if (segments.Count > 0)
            {
                parts.Add(string.Join(", ", segments));
            }
        }
        if (computer.Length > 0)
        {
            parts.Add(computer);
        }
        if (reader.Length > 0)
        {
            parts.Add("lu par " + reader);
        }
        var statusText = (parts.Count > 0 ? string.Join(" · ", parts) + ". " : "") + "Consultation seule : aucune déconnexion depuis cet écran.";
        return new SessionsResult(computer, readAt, state, partial, rows.ToImmutable(), users, unread, system, consoleUser, rdp, disconnected, empty, statusText, reader);
    }

    /// <summary>What an empty or partial list means (Get-DomeniaSessionEmptyText).</summary>
    public static string EmptyText(SourceStatus status, bool incomplete, int users, int rdp, bool consoleOccupied, int unread)
    {
        if (incomplete)
        {
            return "Réponse WTS sans liste de sessions : aucune conclusion sur les sessions ouvertes.";
        }
        return status switch
        {
            SourceStatus.Refused => "Lecture des sessions refusée pour ce compte : aucune conclusion sur les sessions ouvertes.",
            SourceStatus.Unreachable or SourceStatus.Unavailable or SourceStatus.Error => "Poste injoignable ou lecture WTS impossible : aucune conclusion sur les sessions ouvertes.",
            SourceStatus.Partial => "Lecture WTS partielle : liste incomplète, aucune conclusion sur les sessions non listées. Une console vide ne signifie pas absence de session RDP.",
            SourceStatus.Skipped => "Sessions non lues. La lecture WTS se lance par le bouton Lire.",
            _ when unread > 0 => "Lecture WTS partielle : " + FrenchText.Count(unread, "session", "sessions") + " dont le compte n’a pas pu être lu. Aucune conclusion sur ces sessions.",
            _ when users <= 0 => "Aucune session utilisateur ouverte lors de la lecture WTS.",
            _ when !consoleOccupied && rdp > 0 => "Console vide : cela ne signifie pas absence de session RDP. " + FrenchText.Count(rdp, "session RDP ouverte", "sessions RDP ouvertes") + ".",
            _ => "",
        };
    }

    /// <summary>Summary of the sessions in the restart plan: a failed read concludes nothing and recommends the delay.</summary>
    public static RestartSessions ForRestart(SessionsResult? view, string? failure)
    {
        const string Advice = " Une session peut être ouverte : préférez le redémarrage différé avec message.";
        if (!string.IsNullOrWhiteSpace(failure))
        {
            return new RestartSessions(false, -1, [], "Sessions non lues : " + PosteText.Flat(failure, 200) + Advice);
        }
        if (view is null)
        {
            return new RestartSessions(false, -1, [], "Lecture des sessions ouvertes en cours…");
        }
        if (view.ReadState != FactState.Observed)
        {
            return new RestartSessions(false, -1, [], (view.EmptyText.Length > 0 ? view.EmptyText : "Sessions non lues : aucune conclusion.") + Advice);
        }
        var lines = view.Rows.Select(r => string.Join(" · ", new[] { r.User, r.Protocol, r.State, r.Opened.Length > 0 ? "ouverte à " + r.Opened : "", r.Idle.Length > 0 ? "inactive depuis " + r.Idle : "" }.Where(t => t.Length > 0))).ToImmutableArray();
        var count = view.UserSessions;
        var text = count switch
        {
            0 => "Aucune session utilisateur ouverte lors de la lecture.",
            // The mode is chosen after this reading: the sentence holds for both (Domenia 1 Get-DomeniaRestartSessionSummary).
            1 => "1 session ouverte : en différé, l’utilisateur voit le message et le délai ; en immédiat, son travail non enregistré est perdu.",
            _ => FrenchText.Integer(count) + " sessions ouvertes : en différé, chaque utilisateur voit le message et le délai ; en immédiat, leur travail non enregistré est perdu.",
        };
        if (view.UnreadSessions > 0)
        {
            text += " " + FrenchText.Count(view.UnreadSessions, "session", "sessions") + " dont le compte n’a pas pu être lu.";
        }
        if (view.Partial)
        {
            text += " Lecture partielle : aucune conclusion sur les sessions non listées.";
        }
        return new RestartSessions(true, count, lines, text);
    }
}
