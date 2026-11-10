# iConvert

A file converter for the Mac. Drop files or folders onto the window, pick a format, and the result appears next to the original. It never overwrites an existing file.

## Running it

Open `iConvert.xcodeproj` in Xcode and press ⌘R. Requires macOS 15 or later. No developer account or other dependencies are needed.

## Formats

Built into macOS, with nothing to install:

| Kind | Reads | Writes |
|---|---|---|
| Video | MP4, MOV, M4V, 3GP | MP4, MOV, M4V (H.264 or HEVC), animated GIF |
| Audio | MP3, M4A, AAC, WAV, AIFF, FLAC, CAF, audio from videos | M4A, WAV, AIFF, FLAC, CAF |
| Images | JPEG, PNG, HEIC, TIFF, GIF, BMP, WebP, AVIF, JPEG 2000, JPEG XL, ICO, TGA, PSD, RAW, PDF pages | JPEG, PNG, HEIC, TIFF, GIF, BMP, AVIF, JPEG 2000, ICO, TGA, PSD, PDF |
| Documents | TXT, Markdown, HTML, RTF, DOC, DOCX, ODT, PDF | TXT, HTML, RTF, DOC, DOCX, ODT, PDF |

Optional tools. The app finds them on its own once installed, and the puzzle-piece button shows the commands:

| Tool | Adds |
|---|---|
| FFmpeg | MP3, AAC, OGG and Opus; MKV, WebM and AVI for reading and writing; WMV, FLV and MPEG for reading |
| Pandoc | Markdown output, EPUB, LaTeX |
| LibreOffice | Excel, PowerPoint, and Word to PDF with images and tables |
| ImageMagick | WebP output, SVG input |

```bash
brew install ffmpeg pandoc imagemagick
brew install --cask libreoffice
```

## Known limitations

- OGG files made by iConvert contain Opus audio, because Homebrew's FFmpeg has no Vorbis encoder.
- Without LibreOffice, images and tables in Word documents are lost.
- With the built-in converters, audio with more than two channels is mixed down to stereo.
- Text can only be extracted from PDFs that contain it. Scans would need OCR, which the app doesn't do.
- The app isn't sandboxed, because it writes next to the originals, so it isn't suitable for the Mac App Store as is.

## Finder

Besides drag and drop, the app appears in the right-click menu under **Open With** and under **Quick Actions/Services → Convert with iConvert**.

## Project layout

- `iConvert/Model`: formats, options and the conversion queue
- `iConvert/Engines`: one converter per engine. `EngineRegistry` picks which one to use
- `iConvert/Views`: SwiftUI interface
- `iConvertTests`: tests that build real files and convert them with the system encoders and installed tools (⌘U in Xcode)
