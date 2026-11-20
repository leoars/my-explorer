# My Explorer

[English](README.md) · [Português (Brasil)](README.pt-BR.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Italiano](README.it.md)

My Explorer è un gestore di file nativo per macOS. Unisce l’albero delle cartelle, le schede e la vista dettagliata di Esplora file di Windows ai volumi, al Cestino e alle applicazioni del Mac.

![Elenco in italiano filtrato per nome, con due schede aperte](docs/screenshots/navigation-it.png)

## Installare l’app firmata

Apri il DMG della versione preliminare, copia **My Explorer** in **Applicazioni**, espelli l’immagine e apri l’app. La versione 26 ha una firma Apple Development e non è stata autenticata tramite notarizzazione. [GitHub Releases](https://github.com/leoars/my-explorer/releases/tag/v0.1.0-private-beta.11-build26)

## Compilare e installare

Servono macOS 14 o successivo e Xcode con Swift 6. Apri Terminale nella cartella che contiene `Package.swift` ed esegui i comandi seguenti. Per compilare sia per Apple Silicon sia per Intel, anteponi `MY_EXPLORER_ARCHITECTURES='arm64 x86_64'` al comando di compilazione.

```sh
bash scripts/build-app.sh release
open "dist/My Explorer.app"
```

Per installare l’app, chiudila e copia `dist/My Explorer.app` in Applicazioni. Puoi anche aprire `Package.swift` in Xcode. Le build locali usano una firma ad hoc per impostazione predefinita.

## Esplorare e organizzare i file

Seleziona un volume nell’albero o digita un percorso nella barra degli indirizzi. Ogni scheda conserva cronologia, ordinamento e selezione. Il filtro cerca i nomi nella cartella aperta. Trascina le intestazioni per spostare le colonne o regolarne la larghezza.

Copia, taglia e incolla file o cartelle. In caso di conflitto puoi sostituire l’elemento, conservarli entrambi o ignorarlo. Puoi annullare fino a 20 operazioni locali di copia o spostamento per sessione. Il menu contestuale permette di rinominare, condividere, creare archivi ZIP ed estrarli.

Fai clic con il tasto destro su un file e scegli **Proprietà** per consultarne i dettagli. Su un volume nell’albero, ad esempio Macintosh HD, lo stesso comando mostra la capacità totale, lo spazio utilizzato e quello libero.

Per rinominare un elemento nell’elenco, selezionalo, attendi un istante e fai nuovamente clic sul nome. Invio conferma ed Esc annulla. Il doppio clic apre l’elemento. F2 e il comando **Rinomina** aprono la finestra di dialogo.

Nella sessione corrente, Ctrl+Z o ⌘Z ripristina gli elementi dal Cestino nella cartella originale. Se il nome è occupato, annulla per riprovare in seguito oppure conserva entrambi con un nome numerato.

## Lavorare con Git

Nei repository locali i simboli distinguono file modificati, nuovi, ignorati e in conflitto. Dal sottomenu **Git** puoi esaminare separatamente le modifiche nell’indice e nella copia di lavoro per la cartella o i file selezionati.

![Repository di esempio in modalità scura con diversi stati Git](docs/screenshots/git-dark.png)

Consulta la cronologia della selezione e aggiungi o rimuovi file dall’indice. Il commit include l’intero indice. Cambio di branch, fetch, pull e push utilizzano il Git installato sul Mac e richiedono conferma in Terminale.

## Anteprima e riconoscimento del testo

Attiva il pannello di anteprima e seleziona un file locale per visualizzarlo accanto all’elenco. Apri immagini, audio o video nel visualizzatore e usa le frecce per passare da un elemento all’altro. Gli strumenti OCR estraggono testo dalle immagini e dalle scansioni e consentono di creare PDF ricercabili.

![Pannello laterale con l’anteprima del PNG selezionato](docs/screenshots/preview-light.png)

## Cartelle protette e archiviazione cloud

Scegli **Proteggi cartella** dal menu di una cartella locale. Al primo utilizzo crea una password principale e poi una password per la cartella. Per il backup, blocca la cartella e copia l’intero pacchetto `.myexplorervault`. Quando è sbloccata, altre applicazioni con i tuoi permessi possono accedere ai file.

Nelle connessioni cloud puoi configurare un bucket S3 o Google Cloud Storage oppure un contenitore Azure Blob. Le credenziali sono nel Portachiavi di macOS. Puoi copiare tra Mac e cloud. Azure e Google Cloud restano sperimentali e sono testati con servizi simulati.

## Opzioni e aggiornamenti

Apri le **Opzioni** con ⌘ , per ripristinare le schede o l’ultima cartella all’avvio. La conferma di eliminazione è attiva per impostazione predefinita. Disattivandola, Canc sposta subito nel Cestino la selezione locale. Nel cloud l’eliminazione riguarda l’oggetto remoto.

Nelle opzioni puoi abilitare la verifica all’avvio. Puoi aggiornare subito, rimandare di sette giorni o saltare la versione. **Verifica ora** considera anche le versioni rimandate o saltate. Il download inizia dopo la conferma.

## Scorciatoie da tastiera

| ⌨ | Scorciatoie da tastiera |
| --- | --- |
| ⌘ L | Modificare l’indirizzo |
| ⌘ T / ⌘ W | Aprire o chiudere una scheda |
| ⌃ Tab / ⌃ ⇧ Tab | Scheda successiva o precedente |
| ⌘ F / F3 | Filtrare la cartella corrente |
| F2 | Rinominare la selezione |
| Del / Fn + ⌫ | Eliminare la selezione |
| ⌘ Z / Ctrl+Z | Annullare un’operazione locale |

## Automazione locale

Per usare la CLI o un client MCP, apri l’accesso IA dal menu Vista, attiva l’automazione e autorizza le operazioni necessarie su una cartella. Il permesso scade dopo 24 ore. Tieni aperta l’app e importa nel client la configurazione generata in `mcp.json`.

## Test e contributi

Esegui i test Swift e, con la sessione grafica sbloccata, i test dell’interfaccia. Se segnali un problema, indica versione di macOS, architettura, passaggi per riprodurlo e risultato atteso. Usa file di esempio.

```sh
swift test
bash scripts/smoke-test.sh
```

Distribuito con [licenza Apache 2.0](LICENSE). Per le librerie incluse consulta le [note sulle licenze di terze parti](THIRD_PARTY_NOTICES.md).
