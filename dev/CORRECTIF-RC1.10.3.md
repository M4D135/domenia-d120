# Domenia 1.0 RC1.10.3

Correctif de syntaxe PowerShell 5.1 pour `Domenia-Relations.UI.ps1`.

La cause était une apostrophe typographique U+2019 dans une chaîne PowerShell délimitée par apostrophes. PowerShell 5.1 peut interpréter les guillemets typographiques comme délimiteurs. Les quatre occurrences du module Relations utilisent désormais U+02BC, qui reste lisible dans le texte français sans avoir de rôle syntaxique.

Le constructeur des paquets refuse désormais les quatre guillemets typographiques U+2018/U+2019/U+201C/U+201D dans le code PowerShell hors here-strings pour empêcher la même régression.

Le correctif de bootstrap RC1.10.2 est conservé.
