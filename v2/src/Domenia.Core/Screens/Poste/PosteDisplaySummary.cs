namespace Domenia.Core.Poste;

public static class PosteDisplaySummary
{
    public static string Resolution(VideoControllerInfo adapter) => adapter.Width is > 0 && adapter.Height is > 0
        ? FrenchText.Integer(adapter.Width.Value) + " × " + FrenchText.Integer(adapter.Height.Value) + " pixels" : "Résolution non lue";

    public static SheetLine Build(InventorySnapshot inventory, TimeZoneInfo zone)
    {
        var graphics = inventory.VideoControllers;
        if (graphics is null || graphics.Status is not (SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial))
        { return new("computer.display", "Affichage", "Non lu", "Carte graphique et résolution non lues. " + graphics?.Detail, Tone.Off, false); }
        var first = graphics.Controllers.FirstOrDefault();
        var name = first?.Name ?? (graphics.Status == SourceStatus.Empty ? "Aucun contrôleur graphique renvoyé" : "Carte graphique non identifiée");
        var detail = first is null ? "Aucune résolution constatée" : Resolution(first)
            + (first.DriverVersion is { } driver ? " · pilote " + driver : "");
        if (graphics.Controllers.Length > 1) { detail += " · " + FrenchText.Count(graphics.Controllers.Length - 1, "autre contrôleur", "autres contrôleurs") + " dans l’inventaire"; }
        detail += " · relevé du " + PosteText.LocalDateTime(graphics.At, zone)
            + " · mode déclaré par le contrôleur, sans association déduite aux moniteurs EDID";
        return new("computer.display", "Affichage", name, detail, graphics.Status == SourceStatus.Partial ? Tone.Warn : Tone.Info, false);
    }
}
