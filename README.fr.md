# My Explorer

[English](README.md) · [Português (Brasil)](README.pt-BR.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Italiano](README.it.md)

My Explorer est un gestionnaire de fichiers natif pour macOS. Il associe l’arborescence, les onglets et la vue détaillée de l’Explorateur de fichiers Windows aux volumes, à la Corbeille et aux applications du Mac.

![Liste filtrée par nom dans l’interface française, avec deux onglets ouverts](docs/screenshots/navigation-fr.png)

## Installer l’application signée

Ouvrez le DMG de la préversion, copiez **My Explorer** dans **Applications**, éjectez l’image et ouvrez l’application. La version 26 porte une signature Apple Development et n’a pas été notarié. [GitHub Releases](https://github.com/leoars/my-explorer/releases/tag/v0.1.0-private-beta.11-build26)

## Compiler et installer

Il faut macOS 14 ou ultérieur et Xcode avec Swift 6. Ouvrez Terminal dans le dossier contenant `Package.swift` et exécutez les commandes ci-dessous. Pour compiler à la fois pour Apple Silicon et Intel, faites précéder la commande de compilation de `MY_EXPLORER_ARCHITECTURES='arm64 x86_64'`.

```sh
bash scripts/build-app.sh release
open "dist/My Explorer.app"
```

Quittez l’application et copiez `dist/My Explorer.app` dans Applications. Vous pouvez aussi ouvrir `Package.swift` dans Xcode. Par défaut, la compilation locale utilise une signature ad hoc.

## Parcourir et organiser les fichiers

Sélectionnez un volume dans l’arborescence ou saisissez un chemin dans la barre d’adresse. Chaque onglet conserve son historique, son tri et sa sélection. Le filtre porte sur les noms du dossier ouvert. Faites glisser les en-têtes pour déplacer ou redimensionner les colonnes.

Copiez, coupez et collez des fichiers ou des dossiers. En cas de conflit de noms, remplacez l’élément, gardez les deux ou ignorez-le. Vous pouvez annuler jusqu’à 20 copies ou déplacements locaux de la session. Le menu contextuel permet de renommer, de partager, de créer des archives ZIP et de les extraire.

Faites un clic droit sur un fichier et choisissez **Propriétés**. Sur un volume de l’arborescence tel que Macintosh HD, cette commande affiche la capacité totale, l’espace utilisé et l’espace libre.

Pour renommer un élément dans la liste, sélectionnez-le, marquez une pause puis cliquez à nouveau sur son nom. Entrée valide et Échap annule. Un double clic ouvre l’élément. F2 et la commande **Renommer** ouvrent la boîte de dialogue.

Pendant la session, Ctrl+Z ou ⌘Z restaure les éléments de la Corbeille dans leur dossier d’origine. Si le nom est pris, annulez pour réessayer ou conservez les deux avec un nom numéroté.

## Utiliser Git

Dans un dépôt local, des symboles indiquent les fichiers modifiés, nouveaux, ignorés ou en conflit. Le sous-menu **Git** permet de consulter séparément les changements indexés et ceux de la copie de travail pour le dossier ou les fichiers sélectionnés.

![Dépôt de démonstration en mode sombre avec plusieurs états Git](docs/screenshots/git-dark.png)

Consultez l’historique de la sélection et ajoutez ou retirez des fichiers de l’index. Le commit inclut tout l’index. Le changement de branche, fetch, pull et push utilisent Git sur le Mac et demandent une confirmation dans Terminal.

## Prévisualiser les fichiers et reconnaître du texte

Activez le volet d’aperçu et sélectionnez un fichier local pour l’afficher à côté de la liste. Ouvrez les images, les fichiers audio ou les vidéos dans la visionneuse et parcourez-les avec les flèches. L’OCR permet d’extraire le texte d’images et de documents numérisés et de produire des PDF interrogeables.

![Volet latéral affichant un aperçu de l’image PNG sélectionnée](docs/screenshots/preview-light.png)

## Dossiers protégés et stockage en ligne

Choisissez **Protéger le dossier** dans le menu d’un dossier local. À la première utilisation, créez un mot de passe principal puis celui du dossier. Pour une sauvegarde, verrouillez le dossier et copiez le paquet `.myexplorervault` en entier. Une fois déverrouillés, les fichiers sont accessibles aux applications disposant de vos autorisations.

Dans les connexions au stockage en ligne, configurez un bucket S3 ou Google Cloud Storage, ou un conteneur Azure Blob. Les identifiants sont conservés dans le trousseau macOS. La copie fonctionne entre le Mac et le stockage distant. Les intégrations Azure et Google Cloud restent expérimentales et sont testées avec des services simulés.

## Options et mises à jour

Ouvrez les **Options** avec ⌘ , pour restaurer les onglets ou le dernier dossier au démarrage. La confirmation de suppression est activée par défaut. Si vous la désactivez, Suppr envoie la sélection locale directement à la Corbeille. Dans le stockage en ligne, la suppression affecte l’objet distant.

Dans les options, vous pouvez rechercher les mises à jour au démarrage. Vous pouvez installer une mise à jour, reporter la vérification de sept jours ou ignorer la version. **Vérifier maintenant** inclut les versions reportées ou ignorées. Le téléchargement commence après confirmation.

## Raccourcis clavier

| ⌨ | Raccourcis clavier |
| --- | --- |
| ⌘ L | Modifier l’adresse |
| ⌘ T / ⌘ W | Ouvrir ou fermer un onglet |
| ⌃ Tab / ⌃ ⇧ Tab | Onglet suivant ou précédent |
| ⌘ F / F3 | Filtrer le dossier courant |
| F2 | Renommer la sélection |
| Del / Fn + ⌫ | Supprimer la sélection |
| ⌘ Z / Ctrl+Z | Annuler une opération locale |

## Automatisation locale

Pour utiliser la ligne de commande ou un client MCP, ouvrez l’accès IA dans le menu de présentation, activez l’automatisation et autorisez les opérations voulues sur un dossier. Cet accès expire après 24 heures. Gardez l’application ouverte et importez la configuration `mcp.json` dans le client.

## Tester et contribuer

Exécutez les tests Swift puis les tests d’interface dans une session graphique déverrouillée. Pour signaler une anomalie, indiquez la version de macOS, l’architecture, les étapes pour la reproduire et le résultat attendu. Utilisez des fichiers de démonstration.

```sh
swift test
bash scripts/smoke-test.sh
```

Distribué sous [licence Apache 2.0](LICENSE). Les bibliothèques incluses figurent dans les [mentions relatives aux tiers](THIRD_PARTY_NOTICES.md).
