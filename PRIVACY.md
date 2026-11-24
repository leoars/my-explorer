# Privacidade do My Explorer

O My Explorer é um gerenciador de arquivos para macOS desenvolvido por Leonardo Santos. Ele mostra, abre, copia, move, renomeia e apaga os arquivos e pastas do seu Mac, sempre no próprio Mac. O desenvolvedor não recebe nada disso.

## O que fica neste Mac

- **Preferências:** tamanho e posição das janelas, fontes, modo de exibição e ordenação, painel de visualização, extensões visíveis, volume dos vídeos e opções da abertura.
- **Preferidos, pastas recentes, servidores de rede recentes e a sessão** (as abas e a última pasta), para reabrir de onde você parou.
- **Acesso a pastas (versão da App Store):** quando você escolhe "Permitir acesso ao disco" ou "Escolher pastas…", o macOS entrega ao aplicativo uma permissão guardada como marcador (bookmark) nas preferências do aplicativo. Você pode removê-la em Opções › Acesso a pastas…
- **Lixeira e operações interrompidas:** um registro do que o aplicativo mandou para a Lixeira, para poder restaurar, e avisos de cópias ou movimentações interrompidas.
- **Conexões de nuvem (S3, Azure e Google Cloud Storage), se você criar alguma:** o nome, o serviço, o bucket ou contêiner e a região ficam nas preferências; as credenciais (chaves de acesso, tokens) ficam só nas Chaves (Keychain) deste Mac.

## O que sai do Mac, e para onde

- **Nuvem:** quando você usa uma conexão de nuvem, o aplicativo fala direto com o serviço que você configurou (Amazon S3, Microsoft Azure ou Google Cloud Storage), por HTTPS, com as suas credenciais, para listar, baixar, enviar ou apagar o que você pedir. Nada passa pelo desenvolvedor.
- **iCloud Drive:** baixar ou remover a cópia local de um arquivo do iCloud Drive é pedido ao próprio macOS, que fala com o iCloud da sua conta Apple.
- **Rede local:** conectar a um servidor (SMB) é feito pelo macOS, com o servidor que você indicar.
- **Atualizações (só na cópia baixada do GitHub):** essa cópia consulta a lista pública de releases do GitHub ao abrir (o que pode ser desligado em Opções) ou quando você pede, e baixa a nova versão se você aceitar. O GitHub recebe o endereço de rede do Mac, como em qualquer acesso a um site; nenhum conteúdo ou dado pessoal é enviado. A cópia da App Store não faz essa consulta; as atualizações vêm da própria loja.
- **Links e compartilhamento:** se você abrir um link externo, usar o menu Compartilhar do macOS ou enviar um relato pelo GitHub, o serviço escolhido recebe o que você decidir enviar.

O reconhecimento de texto (OCR) e a criação de PDFs pesquisáveis usam o Vision, do próprio macOS, e são feitos no Mac. A visualização de Markdown não busca imagens da internet.

O aplicativo não coleta nem transmite arquivos, nomes de arquivos, conteúdos, dados pessoais, identificadores ou dados de uso ao desenvolvedor. Não inclui anúncios, rastreamento ou ferramentas de análise.

Para falar sobre privacidade, escreva para [Leonardo Santos](mailto:leoars@gmail.com).

## Privacy in English

My Explorer is a macOS file manager developed by Leonardo Santos. It shows, opens, copies, moves, renames and deletes the files and folders on your Mac, always on the Mac itself. None of it reaches the developer.

### What stays on this Mac

- **Preferences:** window size and position, fonts, view and sort settings, the preview pane, visible extensions, video volume and startup options.
- **Favorites, recent folders, recent network servers and the session** (tabs and last folder), to reopen where you left off.
- **Folder access (App Store version):** when you choose "Allow Disk Access" or "Choose Folders…", macOS gives the app a permission stored as a bookmark in the app's preferences. You can remove it in Options › Folder Access…
- **Trash and interrupted operations:** a record of what the app moved to the Trash, so it can be put back, and notices about interrupted copies or moves.
- **Cloud connections (S3, Azure and Google Cloud Storage), if you create any:** the name, service, bucket or container and region are kept in the preferences; the credentials (access keys, tokens) are kept only in this Mac's Keychain.

### What leaves the Mac, and where it goes

- **Cloud:** when you use a cloud connection, the app talks directly to the service you configured (Amazon S3, Microsoft Azure or Google Cloud Storage), over HTTPS, with your credentials, to list, download, upload or delete what you ask for. Nothing goes through the developer.
- **iCloud Drive:** downloading a file from iCloud Drive or removing its local copy is requested from macOS itself, which talks to the iCloud of your Apple Account.
- **Local network:** connecting to a server (SMB) is done by macOS, with the server you enter.
- **Updates (only in the copy downloaded from GitHub):** that copy reads GitHub's public list of releases when it opens (which you can turn off in Options) or when you ask, and downloads the new version if you accept. GitHub receives the Mac's network address, as with any visit to a website; no content or personal data is sent. The App Store copy does not make this check; its updates come from the store.
- **Links and sharing:** if you open an external link, use the macOS Share menu or submit a report on GitHub, the service you choose receives what you decide to send.

Text recognition (OCR) and searchable PDFs use Vision, part of macOS, and run on the Mac. The Markdown preview does not fetch images from the internet.

The app does not collect or transmit files, file names, content, personal information, identifiers or usage data to the developer. It contains no advertising, tracking or analytics.

For privacy questions, contact [Leonardo Santos](mailto:leoars@gmail.com).
