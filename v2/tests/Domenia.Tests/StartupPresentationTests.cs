using System.Drawing;
using System.Text;
using Domenia.App;
using Domenia.App.Secrets;
using Domenia.Core;

namespace Domenia.Tests;

internal static class StartupPresentationTests
{
    [Test]
    public static void Login_bounds_follow_dpi_and_work_area_without_losing_the_window_on_another_monitor()
    {
        foreach (var dpi in new[] { 96, 144, 192 })
        {
            var area = new Rectangle(-1920, 40, 1280, 720);
            var chrome = new Size(16, 38);
            var minimum = LoginLayout.Minimum(area.Size, chrome, dpi);
            Check.True(minimum.Width <= area.Width && minimum.Height <= area.Height, "minimum tient dans l’écran à chaque DPI");
            var position = LoginLayout.Position(area, minimum, new(3000, -200));
            Check.True(area.Contains(new Rectangle(position, minimum)), "position centrée/bornée reste sur le moniteur choisi");
            Check.True(LoginLayout.Compact(new Size(640, 440), dpi), "petit écran utilise le bandeau compact");
            Check.False(LoginLayout.Compact(new Size(1024 * dpi / 96, 660 * dpi / 96), dpi), "format de référence inchangé");
        }
    }

    [Test]
    public static void Startup_monitor_reports_current_phase_and_real_elapsed_time_without_an_estimate()
    {
        var clock = new Clock(); var monitor = new StartupMonitor(clock);
        clock.Seconds = 9;
        Check.Contains("toujours active", monitor.Describe(false, 8), "seuil par étape atteint");
        monitor.Phase("Préparation locale"); clock.Seconds = 10;
        var text = monitor.Describe(false, 8);
        Check.Contains("Étape : 1 s", text, "durée étape remise à zéro"); Check.Contains("Total : 10 s", text, "total conservé");
        Check.False(text.Contains("toujours active", StringComparison.Ordinal), "nouvelle étape pas encore lente");
        Check.Contains("Attente de la fin", monitor.Describe(true, 8), "annulation ne signifie pas terminaison");
        Check.Contains("intégrité", monitor.Diagnostic, "étapes précédentes consultables");
        monitor.Phase("password=ne-pas-garder");
        Check.False(monitor.Diagnostic.Contains("ne-pas-garder", StringComparison.Ordinal), "diagnostic ne conserve pas un secret accidentel");
    }

    [Test]
    public static void Startup_display_settings_are_real_configuration_with_bounded_defaults()
    {
        var defaults = StartupDisplayOptions.Read(ConfigurationRules.Read(null, "test"));
        Check.True(defaults.Show && defaults.KeepUntilReady, "suivi jusqu’au premier écran par défaut"); Check.Equal(8, defaults.WarningSeconds, "seuil de huit secondes");
        var custom = StartupDisplayOptions.Read(ConfigurationRules.Read(Encoding.UTF8.GetBytes("{\"Startup\":{\"ShowMonitor\":false,\"KeepMonitorUntilReady\":false,\"WarnStageSeconds\":20}}"), "test"));
        Check.False(custom.Show || custom.KeepUntilReady, "préférences réellement lues"); Check.Equal(20, custom.WarningSeconds, "seuil effectif");
    }

    private sealed class Clock : TimeProvider
    {
        internal long Seconds;
        public override long TimestampFrequency => 1;
        public override long GetTimestamp() => Seconds;
    }
}
