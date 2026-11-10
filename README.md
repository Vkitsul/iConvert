# iConvert

Convertitore di file per Mac: trascini file o cartelle nella finestra, scegli il formato e trovi il risultato accanto all'originale. Non sovrascrive mai un file esistente.

## Avvio

Apri `iConvert.xcodeproj` in Xcode e premi ⌘R. Serve macOS 15 o successivo; non servono un account sviluppatore né altre dipendenze.

## Formati

Funzionano senza installare nulla:

| Tipo | Legge | Scrive |
|---|---|---|
| Video | MP4, MOV, M4V, 3GP | MP4, MOV, M4V (H.264 o HEVC), GIF animata |
| Audio | MP3, M4A, AAC, WAV, AIFF, FLAC, CAF, audio dei video | M4A, WAV, AIFF, FLAC, CAF |
| Immagini | JPEG, PNG, HEIC, TIFF, GIF, BMP, WebP, AVIF, JPEG 2000, JPEG XL, ICO, TGA, PSD, RAW, pagine PDF | JPEG, PNG, HEIC, TIFF, GIF, BMP, AVIF, JPEG 2000, ICO, TGA, PSD, PDF |
| Documenti | TXT, Markdown, HTML, RTF, DOC, DOCX, ODT, PDF | TXT, HTML, RTF, DOC, DOCX, ODT, PDF |

Strumenti facoltativi, che l'app trova da sola una volta installati (il pulsante a forma di puzzle mostra i comandi):

| Strumento | Aggiunge |
|---|---|
| FFmpeg | MP3, AAC, OGG e Opus; MKV, WebM e AVI in lettura e scrittura; WMV, FLV e MPEG in sola lettura |
| Pandoc | Markdown in uscita, EPUB, LaTeX |
| LibreOffice | Excel, PowerPoint, e Word in PDF con immagini e tabelle |
| ImageMagick | WebP in uscita, SVG in ingresso |

## Limiti noti

- I file OGG creati da iConvert contengono audio Opus: il FFmpeg di Homebrew non include il codificatore Vorbis.
- Senza LibreOffice, immagini e tabelle dei documenti Word si perdono nella conversione.
- L'audio con più di due canali viene ridotto a stereo con i convertitori integrati.
- Il testo si estrae solo dai PDF che lo contengono: per le scansioni servirebbe l'OCR, che l'app non fa.
- L'app non è in sandbox perché deve scrivere accanto agli originali, quindi non è adatta al Mac App Store così com'è.

## Finder

Oltre al trascinamento, l'app compare nel menu del tasto destro in **Apri con** e in **Azioni rapide/Servizi → Converti con iConvert**.

## Struttura

- `iConvert/Model`: formati, opzioni e coda delle conversioni
- `iConvert/Engines`: un convertitore per ogni motore. `EngineRegistry` sceglie quale usare
- `iConvert/Views`: interfaccia SwiftUI
- `iConvertTests`: test che creano file veri e li convertono con i codificatori di sistema (⌘U in Xcode)
