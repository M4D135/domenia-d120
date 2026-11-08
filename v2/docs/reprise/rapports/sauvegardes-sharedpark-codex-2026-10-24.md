# Sauvegardes physiques SharedPark — renfort Codex

Deux fichiers nouveaux, développés puis relus par un second agent et le coordinateur. Capture064 compilée dans la VM Windows : Debug/Release zéro avertissement et zéro erreur,62s. Vingt-quatre tests comportementaux écrits et compilés, **aucun exécuté**.

API interne `CreateSharedParkBackupsAsync` : copies SQLite cohérentes via API backup native depuis une transaction de lecture, incluant WAL ; copie autonome relue avec quick_check/identités/empreinte logique, puis SHA physique. TSV sauvegardé octet pour octet (BOM, ordre et dates compris), dans la limite16Mio. Absence observée distincte d’un fichier présent vide. Références seulement après copies effectivement relues ; aucun accès aux copies déduit d’une simple métadonnée.

Dossier parent privé existant requis, DACL vérifiée sans réparation. Lot créé exclusivement avec DACL ; fichiers créés exclusivement, scellés en lecture et relus par handles qualifiés, identité physique et liens contrôlés. Quotas32lots/1Gio sous admission interprocessus exclusive, scan borné, marge disque, preuves conservées après annulation/erreur. Le verrou préexistant n’est jamais adopté ni nettoyé. La revue a corrigé reparse terminal, DACL finale, quotas concurrents et faux positifs de hooks.

**Limites** : aucune publication ni transaction de fusion, aucun reçu métier, aucun raccordementUI/cache. Relectures et capture cohérente ne remplacent pas le futur doubleCAS des sources sous verrou de publication. Le propriétaire peut modifier volontairement les permissions d’une preuve ; les consommateurs doivent toujours relire les SHA. Les deux ressources ne deviennent pas atomiques. Le prochain lot relie sauvegardes, intention durable, publication, transaction et vérification sans rejeu automatique.

Sources compilées :
- v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Backups.cs : `397f0f4cdf11f7146e132c75f375d747ce4964a876746647b2b6e46a09ffff1d`
- v2/tests/Domenia.Tests/SharedParkBackupTests.cs : `25676277e2f6c26e7f224677dadbf293672b419f47e94ab35c941f695bf6ccd6`
