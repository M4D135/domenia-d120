using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using static Domenia.Tests.Fixtures;

namespace Domenia.Tests;

internal static class DashboardCalculatorTests
{
    [Test]
    public static void Calculation_is_pure()
    {
        var pc = Computer("PC-1");
        var input = Input(Snapshot([User("alice")], [pc]), [Observe(pc, Presence(true, TimeSpan.FromHours(1)), Disk(1000, 50, TimeSpan.FromHours(2)))],
            journal: [new JournalEntry(Now - TimeSpan.FromMinutes(3), "Essai", Tone.Ok)]);
        var first = JsonSerializer.Serialize(DashboardCalculator.Compute(input), BridgeJson.Options);
        var second = JsonSerializer.Serialize(DashboardCalculator.Compute(input), BridgeJson.Options);
        Check.Equal(first, second, "même entrée, même JSON");
        Check.Equal(1, input.State.Directory.Users.Length, "entrée inchangée");
        Check.Equal(1, input.Journal.Length, "journal inchangé");
    }

    [Test]
    public static void Lockout_time_alone_is_never_a_lock()
    {
        var users = new[]
        {
            User("locked") with { ComputedAccountControl = AdValues.LockedOut, LockoutTime = Ft(Now - TimeSpan.FromMinutes(5)) },
            User("expired-lock") with { ComputedAccountControl = 0, LockoutTime = Ft(Now - TimeSpan.FromHours(3)) },
            User("unreadable") with { ComputedAccountControl = null, LockoutTime = Ft(Now - TimeSpan.FromMinutes(5)) },
            User("disabled") with { UserAccountControl = AdValues.NormalAccount | AdValues.AccountDisabled, ComputedAccountControl = AdValues.LockedOut },
        };
        var widget = Widget(WidgetCatalog.LockedAccounts, Input(Snapshot(users)));
        var kpi = Kpi(widget);
        Check.Equal(1, kpi.Value, "un seul verrouillé");
        Check.Equal(1, Part(kpi.Breakdown, "toCheck"), "calcul illisible → à vérifier");
        Check.Equal(Tone.Alert, widget.Tone, "ton alerte");
    }

    [Test]
    public static void Password_window_is_open_on_now_and_closed_on_seven_days()
    {
        DirectoryUser Expiring(string name, DateTimeOffset expiry) => User(name) with { PasswordExpiryComputed = Ft(expiry) };
        var users = new[]
        {
            Expiring("now", Now),
            Expiring("seven", Now + TimeSpan.FromDays(7)),
            Expiring("seven-plus", Now + TimeSpan.FromDays(7) + TimeSpan.FromSeconds(1)),
            Expiring("flagged", Now + TimeSpan.FromDays(3)) with { ComputedAccountControl = AdValues.PasswordExpired },
            User("never") with { UserAccountControl = AdValues.NormalAccount | AdValues.DontExpirePassword, PasswordExpiryComputed = AdValues.Never },
            User("must") with { PasswordLastSet = 0, PasswordExpiryComputed = 0 },
            Expiring("disabled", Now + TimeSpan.FromDays(2)) with { UserAccountControl = AdValues.NormalAccount | AdValues.AccountDisabled },
        };
        var kpi = Kpi(Widget(WidgetCatalog.PasswordsExpiring, Input(Snapshot(users))));
        Check.Equal(1, kpi.Value, "seul « maintenant + 7 jours » est compté");
        Check.Equal(2, Part(kpi.Breakdown, "expired"), "maintenant et bit 0x800000 → expirés");
        Check.Equal(1, Part(kpi.Breakdown, "mustChange"), "pwdLastSet = 0");
        Check.Equal(1, Part(kpi.Breakdown, "neverExpires"), "n’expire jamais");
    }

    [Test]
    public static void Disabled_accounts_are_not_active_and_computers_are_not_accounts()
    {
        var users = new[] { User("a"), User("b"), User("c") with { UserAccountControl = AdValues.NormalAccount | AdValues.AccountDisabled } };
        var kpi = Kpi(Widget(WidgetCatalog.ActiveAccounts, Input(Snapshot(users, [Computer("PC-1"), Computer("PC-2")]))));
        Check.Equal(2, kpi.Value, "actifs");
        Check.Equal(1, Part(kpi.Breakdown, "disabled"), "désactivés");
        Check.Null(kpi.Total, "pas de dénominateur");
    }

    [Test]
    public static void Presence_older_than_thirty_days_is_not_checked_and_no_answer_stays_informative()
    {
        var pcs = new[] { Computer("PC-1"), Computer("PC-2"), Computer("PC-3"), Computer("PC-4") };
        var observations = new[]
        {
            Observe(pcs[0], Presence(true, TimeSpan.FromHours(2))),
            Observe(pcs[1], Presence(false, TimeSpan.FromDays(2))),
            Observe(pcs[2], Presence(true, TimeSpan.FromDays(31))),
            Observe(pcs[3]),
        };
        var widget = Widget(WidgetCatalog.WorkstationsOnline, Input(Snapshot(computers: pcs), observations));
        var kpi = Kpi(widget);
        Check.Equal(1, kpi.Value, "en ligne");
        Check.Equal(4, kpi.Total, "total");
        Check.Equal(1, Part(kpi.Breakdown, "noAnswer"), "sans réponse");
        Check.Equal(2, Part(kpi.Breakdown, "notChecked"), "31 jours → non vérifié");
        Check.Equal(Tone.Info, widget.Tone, "une absence de réponse n’est jamais une alerte");
        Check.Equal(Now - TimeSpan.FromHours(2), widget.MeasuredAt, "relevé le plus récent");
    }

    [Test]
    public static void Disk_thresholds_follow_the_health_rules()
    {
        var pcs = Enumerable.Range(1, 6).Select(i => Computer("PC-" + i)).ToArray();
        var observations = new[]
        {
            Observe(pcs[0], inventory: Disk(1000, 99, TimeSpan.FromHours(1))),
            Observe(pcs[1], inventory: Disk(1000, 100, TimeSpan.FromHours(1))),
            Observe(pcs[2], inventory: Disk(1000, 199, TimeSpan.FromHours(1))),
            Observe(pcs[3], inventory: Disk(1000, 200, TimeSpan.FromHours(1))),
            Observe(pcs[4], inventory: Disk(0, 0, TimeSpan.FromHours(1))),
            Observe(pcs[5]),
        };
        var widget = Widget(WidgetCatalog.DiskAlerts, Input(Snapshot(computers: pcs), observations));
        var kpi = Kpi(widget);
        Check.Equal(1, Part(kpi.Breakdown, "critical"), "9,9 % critique");
        Check.Equal(2, Part(kpi.Breakdown, "tight"), "10,0 % et 19,9 % serrés");
        Check.Equal(1, Part(kpi.Breakdown, "healthy"), "20,0 % sain");
        Check.Equal(2, Part(kpi.Breakdown, "unknown"), "taille nulle → sans relevé");
        Check.Equal(Tone.Alert, widget.Tone, "ton alerte");
        Check.Contains("4 postes relevés sur 6", widget.Detail, "postes relevés");

        var none = Widget(WidgetCatalog.DiskAlerts, Input(Snapshot(computers: pcs), [Observe(pcs[0])]));
        Check.Null(none.Data, "aucun relevé → pas de données");
        Check.True(none.Enabled && none.Tone == Tone.Off && none.MeasuredAt is null, "jamais mesuré");
    }

    [Test]
    public static void Freshness_breakdown_sums_to_the_total()
    {
        var pcs = Enumerable.Range(1, 7).Select(i => Computer("PC-" + i)).ToArray();
        var observations = new[]
        {
            Observe(pcs[0], Presence(true, TimeSpan.FromHours(1))),
            Observe(pcs[1], Presence(false, TimeSpan.FromDays(6))),
            Observe(pcs[2], Presence(false, TimeSpan.FromDays(8))),
            Observe(pcs[3], Presence(false, TimeSpan.FromDays(29))),
            Observe(pcs[4], Presence(false, TimeSpan.FromDays(45))),
            Observe(pcs[5]),
            Observe(pcs[6], new PresenceMeasure(MeasureState.Error, null, null, null)),
        };
        var widget = Widget(WidgetCatalog.MeasureFreshness, Input(Snapshot(computers: pcs), observations));
        var gauge = (GaugeData)widget.Data!;
        Check.Equal(2, gauge.Fresh, "récents");
        Check.Equal(7, gauge.Total, "total");
        Check.Equal(28.6, gauge.Percent, "pourcentage au dixième");
        Check.Equal(gauge.Total, gauge.Breakdown.Sum(b => b.Value), "somme de la ventilation");
        Check.Equal(2, Part(gauge.Breakdown, "aging"), "7 à 30 jours");
        Check.Equal(1, Part(gauge.Breakdown, "expired"), "plus de 30 jours");
        Check.Equal(2, Part(gauge.Breakdown, "never"), "jamais relevé, sonde en erreur comprise");
        Check.Equal(Tone.Alert, widget.Tone, "moins de 60 % → alerte");
    }

    [Test]
    public static void Systems_are_grouped_and_percentages_sum_to_one_hundred()
    {
        var specs = new (string Os, string Version, int Count)[]
        {
            ("Windows 11 Entreprise", "10.0 (26100)", 3),
            ("Windows 11 Professionnel", "10.0 (26100)", 2),
            ("Windows 11 Entreprise", "10.0 (22631)", 2),
            ("Windows 10 Entreprise", "10.0 (19045)", 1),
            ("Windows 10 Entreprise LTSC", "10.0 (19044)", 1),
            ("Windows 11 Entreprise", "10.0 (26200)", 1),
        };
        var pcs = specs.SelectMany((s, i) => Enumerable.Range(0, s.Count).Select(k => Computer($"PC-{i}-{k}") with { OperatingSystem = s.Os, OperatingSystemVersion = s.Version }))
            .Append(Computer("PC-X") with { OperatingSystem = null, OperatingSystemVersion = null })
            .ToArray();
        var data = (DistributionData)Widget(WidgetCatalog.OsDistribution, Input(Snapshot(computers: pcs))).Data!;
        Check.Equal(11, data.Total, "total");
        Check.Equal("11 postes", data.CenterText, "texte central");
        Check.Equal(5, data.Segments.Length, "4 segments + autres");
        Check.Equal("Windows 11 24H2", data.Segments[0].Label, "éditions regroupées en tête");
        Check.Equal(5, data.Segments[0].Value, "Entreprise et Professionnel ensemble");
        Check.Equal("Windows 11 23H2", data.Segments[1].Label, "deuxième");
        Check.Equal("Système non renseigné", data.Segments[2].Label, "égalité de valeur : ordre du libellé");
        Check.Equal("autres", data.Segments[4].Key, "autres en dernier");
        Check.Equal(2, data.Segments[4].Members.Length, "membres regroupés");
        Check.Equal(100.0, Math.Round(data.Segments.Sum(s => s.Percent), 1), "somme exacte de 100,0");
        Check.Equal("Windows 11 24H2", data.Lead!.Label, "segment dominant");
    }

    [Test]
    public static void Activity_has_seven_points_with_missing_days_left_empty()
    {
        var pc = Computer("PC-1");
        var today = LocalDays.DateOf(Now, TestClock.Paris);
        var history = new[]
        {
            new DailyFigures(today.AddDays(-1), 10, 12, null, null, null, null),
            new DailyFigures(today.AddDays(-3), 9, 11, null, null, null, null),
        };
        var widget = Widget(WidgetCatalog.WorkstationActivity, Input(Snapshot(computers: [pc]), [Observe(pc, Presence(true, TimeSpan.FromMinutes(30)))], history));
        var series = (SeriesData)widget.Data!;
        Check.Equal(7, series.Points.Length, "toujours 7 points");
        Check.Equal(today, series.Points[6].Date, "aujourd’hui en dernier");
        Check.True(series.Points[6].Partial && series.Points.Take(6).All(p => !p.Partial), "seul aujourd’hui est partiel");
        Check.Equal(1, series.Points[6].Value, "postes vus aujourd’hui");
        Check.Equal(12, series.Points[5].Value, "veille");
        Check.Null(series.Points[4].Value, "jour sans instantané : vide, jamais 0");
        Check.Equal(12, series.Max, "échelle");
        Check.Equal("mer.", series.Points[6].Label, "jour abrégé figé");
    }

    [Test]
    public static void History_skips_missing_days_and_delta_needs_the_point_of_last_week()
    {
        var today = LocalDays.DateOf(Now, TestClock.Paris);
        var users = new[] { User("a") with { ComputedAccountControl = AdValues.LockedOut } };
        var withWeekAgo = new[] { new DailyFigures(today.AddDays(-7), null, null, null, 2, null, null), new DailyFigures(today.AddDays(-2), null, null, null, 0, null, null) };
        var kpi = Kpi(Widget(WidgetCatalog.LockedAccounts, Input(Snapshot(users), history: withWeekAgo)));
        Check.Equal(3, kpi.History.Length, "deux instantanés et aujourd’hui");
        Check.Equal(-1, kpi.Delta!.Value, "écart sur 7 jours");
        Check.Equal("−1 sur 7 jours", kpi.Delta.Label, "libellé avec signe moins");
        Check.Equal(Tone.Ok, kpi.Delta.Tone, "baisse des verrouillages : ok");
        Check.Equal("P7D", kpi.Delta.Period, "période");

        var without = Kpi(Widget(WidgetCatalog.LockedAccounts, Input(Snapshot(users), history: [new DailyFigures(today.AddDays(-6), null, null, null, 4, null, null)])));
        Check.Null(without.Delta, "pas de point à J−7 : pas d’écart");
        Check.Equal("+9 sur 7 jours", FrenchText.DeltaLabel(9, 7), "hausse");
        Check.Equal("Stable sur 7 jours", FrenchText.DeltaLabel(0, 7), "stable");
    }

    [Test]
    public static void Watchlist_orders_by_severity_rule_value_then_name()
    {
        var pcs = new[]
        {
            Computer("PC-B"),
            Computer("PC-A"),
            Computer("PC-C") with { LastLogonTimestamp = null },
            Computer("PC-D") with { LastLogonTimestamp = Ft(Now - TimeSpan.FromDays(120)), PasswordLastSet = Ft(Now - TimeSpan.FromDays(125)) },
            Computer("PC-E"),
            Computer("PC-F"),
            Computer("PC-G"),
            Computer("PC-H"),
        };
        var observations = new[]
        {
            Observe(pcs[0], inventory: Disk(1000, 50, TimeSpan.FromHours(1))),
            Observe(pcs[1], inventory: Disk(1000, 50, TimeSpan.FromHours(1))),
            Observe(pcs[2]),
            Observe(pcs[3]),
            Observe(pcs[4], inventory: Disk(1000, 150, TimeSpan.FromHours(1))),
            Observe(pcs[5], inventory: Disk(1000, 500, TimeSpan.FromHours(1), TimeSpan.FromDays(40))),
            Observe(pcs[6], inventory: Disk(1000, 30, TimeSpan.FromHours(1))),
            Observe(pcs[7], inventory: Disk(1000, 500, TimeSpan.FromHours(1))),
        };
        var widget = Widget(WidgetCatalog.Watchlist, Input(Snapshot(computers: pcs), observations));
        var list = (WatchlistData)widget.Data!;
        Check.Equal(7, list.Total, "postes distincts avec un point");
        Check.Equal(6, list.Shown, "au plus 6 lignes");
        Check.Equal("PC-G", list.Rows[0].Name, "disque le plus plein d’abord");
        Check.Equal("PC-A", list.Rows[1].Name, "égalité de valeur : ordre du nom");
        Check.Equal("PC-B", list.Rows[2].Name, "puis PC-B");
        Check.Equal(WatchRule.NeverLoggedOn, list.Rows[3].RuleId, "puis jamais connecté");
        Check.Equal(WatchRule.Stale, list.Rows[4].RuleId, "puis inactif");
        Check.Equal(1, list.Rows[4].OtherReasons, "mot de passe machine ancien en plus");
        Check.Equal(WatchRule.DiskTight, list.Rows[5].RuleId, "puis disque serré");
        Check.Equal(Tone.Alert, widget.Tone, "une ligne en alerte");
        Check.Equal("Disque C: presque plein : 3,0 % libre", list.Rows[0].Reason, "motif avec la valeur mesurée");
    }

    [Test]
    public static void Watchlist_without_recent_inventory_gives_no_healthy_verdict()
    {
        var pc = Computer("PC-1");
        var empty = Widget(WidgetCatalog.Watchlist, Input(Snapshot(computers: [pc]), [Observe(pc, Presence(true, TimeSpan.FromHours(1)))]));
        Check.Equal(Tone.Info, empty.Tone, "liste vide sans inventaire : pas de vert");
        Check.Equal(0, ((WatchlistData)empty.Data!).Total, "aucune ligne");
        Check.Contains("disques et redémarrages non évalués", empty.Detail, "limite de la mesure dite");
        var never = Computer("PC-2") with { LastLogonTimestamp = null };
        var withRow = Widget(WidgetCatalog.Watchlist, Input(Snapshot(computers: [never]), [Observe(never)]));
        Check.Equal(Tone.Warn, withRow.Tone, "les règles de l’annuaire restent évaluées");
        Check.Contains("non évalués", withRow.Detail, "limite dite aussi avec des lignes");
        var old = Widget(WidgetCatalog.Watchlist, Input(Snapshot(computers: [pc]), [Observe(pc, inventory: Disk(1000, 500, TimeSpan.FromDays(40)))]));
        Check.True(old.Tone != Tone.Ok, "inventaire de plus de 30 jours : pas de vert");
        Check.Contains("non évalués", old.Detail, "inventaire trop ancien : limite dite");
        var healthy = Widget(WidgetCatalog.Watchlist, Input(Snapshot(computers: [pc]), [Observe(pc, inventory: Disk(1000, 500, TimeSpan.FromHours(1)))]));
        Check.Equal(Tone.Ok, healthy.Tone, "inventaire récent sans point : vert");
        Check.Equal("Aucun point d’attention sur les postes du périmètre.", healthy.Detail, "détail inchangé");
    }

    [Test]
    public static void Disabled_widget_has_no_data_and_unmeasured_widget_stays_enabled()
    {
        var input = Input(Snapshot([User("a")]), disabled: [WidgetCatalog.LockedAccounts]);
        var disabled = Widget(WidgetCatalog.LockedAccounts, input);
        Check.False(disabled.Enabled, "désactivé");
        Check.Null(disabled.Data, "aucune donnée");
        Check.Equal(Tone.Off, disabled.Tone, "ton off");
        Check.Null(disabled.MeasuredAt, "aucune date de mesure");
        Check.False(disabled.Stale, "jamais périmé");
        Check.Equal(DashboardCalculator.DisabledDetail, disabled.Detail, "texte fixe");

        var unmeasured = Widget(WidgetCatalog.WorkstationsOnline, input);
        Check.True(unmeasured.Enabled, "actif");
        Check.Null(unmeasured.Data, "jamais mesuré : pas de données");
        Check.Equal(Tone.Off, unmeasured.Tone, "ton off");

        var summary = DashboardCalculator.Compute(input);
        Check.Equal(10, summary.Widgets.Count, "10 widgets, désactivés compris");
        Check.True(summary.Widgets.Keys.SequenceEqual(WidgetCatalog.All.Select(w => w.Id)), "ordre du contrat");
        foreach (var widget in summary.Widgets.Values)
        {
            Check.Equal(widget.Data is null, !widget.Enabled || widget.MeasuredAt is null, "data nul si et seulement si désactivé ou jamais mesuré : " + widget.Id);
        }
    }

    [Test]
    public static void Measure_older_than_seven_days_is_stale_and_grey()
    {
        var input = Input(Snapshot([User("a")], readAt: Now - TimeSpan.FromDays(8)));
        var widget = Widget(WidgetCatalog.ActiveAccounts, input);
        Check.True(widget.Stale, "périmé");
        Check.Equal(Tone.Off, widget.Tone, "grisé");
        Check.NotNull(widget.Data, "les données restent lisibles");
        Check.False(Widget(WidgetCatalog.ActiveAccounts, Input(Snapshot([User("a")], readAt: Now - TimeSpan.FromDays(6)))).Stale, "6 jours : à jour");
    }

    [Test]
    public static void Disabled_and_out_of_scope_computers_are_not_counted()
    {
        var inScope = Computer("PC-1");
        var quarantined = Computer("PC-2", "OU=Quarantaine," + Postes) with { UserAccountControl = AdValues.WorkstationTrustAccount | AdValues.AccountDisabled };
        var joined = Computer("DESKTOP-1", "CN=Computers," + Root);
        var nested = Computer("PC-3", "OU=Lyon," + Postes);
        var data = (DistributionData)Widget(WidgetCatalog.OsDistribution, Input(Snapshot(computers: [inScope, quarantined, joined, nested]))).Data!;
        Check.Equal(2, data.Total, "seuls les postes actifs de l’OU Postes et de ses sous-OU");
    }

    [Test]
    public static void Recent_operations_show_six_rows_most_recent_first()
    {
        var journal = Enumerable.Range(1, 8).Select(i => new JournalEntry(Now - TimeSpan.FromMinutes(i), "Opération " + i, Tone.Ok)).Reverse().ToArray();
        var widget = Widget(WidgetCatalog.RecentOperations, Input(Snapshot(), journal: journal));
        var data = (TimelineData)widget.Data!;
        Check.Equal(8, data.Total, "entrées disponibles");
        Check.Equal(6, data.Rows.Length, "6 lignes");
        Check.Equal("Opération 1", data.Rows[0].Label, "la plus récente d’abord");
        Check.Equal(Now - TimeSpan.FromMinutes(1), widget.MeasuredAt, "entrée la plus récente");
        Check.Null(Widget(WidgetCatalog.RecentOperations, Input(Snapshot())).Data, "journal vide : jamais mesuré");
    }

    [Test]
    public static void French_numbers_use_the_contract_separators()
    {
        Check.Equal("1 826", FrenchText.Integer(1826), "séparateur de milliers");
        Check.Equal("−3", FrenchText.Integer(-3), "signe moins");
        Check.Equal("3,1 %", FrenchText.Percent(3.1), "pourcentage");
        Check.Equal("1 234,5", FrenchText.Decimal(1234.5), "décimal");
        Check.Equal("1 poste", FrenchText.Count(1, "poste", "postes"), "singulier");
        Check.Equal("0 poste", FrenchText.Count(0, "poste", "postes"), "zéro au singulier");
        double[] expected = [54.1, 23.3, 14.1, 5.6, 2.9];
        Check.True(expected.SequenceEqual(DashboardCalculator.LargestRemainderPercents([223, 96, 58, 23, 12])), "plus fort reste (exemple du contrat)");
    }
}
