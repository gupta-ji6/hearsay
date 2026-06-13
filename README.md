<h1>  <img src="assets/icon_128.png" alt="Hearsay icon" width="30"/> Hearsay</h1>

**[Download Hearsay 1.0.23 DMG](https://github.com/swairshah/hearsay/releases/download/v1.0.23/Hearsay-1.0.23.dmg)**

Browse all [Releases](https://github.com/swairshah/hearsay/releases).

__Local speech-to-text for macOS__.

You can also install with Homebrew:

```bash
brew install --cask swairshah/tap/hearsay
```

Hold Right Option to record, release to transcribe, auto-paste at cursor.

Hearsay supports multiple local speech model backends:

- Qwen3-ASR through Antirez's <a href="https://github.com/antirez/qwen-asr">qwen-asr</a>
- Whisper models through WhisperKit
- NVIDIA Parakeet models through FluidAudio

### Local models FTW.

![Demo](assets/demo.gif)

## Usage

| Action | How |
|--------|-----|
| **Record** | Hold **Right Option (⌥)** |
| **Transcribe** | Release the key |
| **Toggle mode** | **Right Option + Space** to start/stop |

Transcribed text is automatically pasted at your cursor and copied to clipboard.

## CLI

Homebrew cask installs can expose the bundled `hearsay` command when the cask includes the binary stanza for the app bundle.

```bash
hearsay open
hearsay health
hearsay dictate --stop-on-enter
hearsay history --limit 5
hearsay logs
hearsay logs --open
```

Apps and editor extensions can use Hearsay as a local dictation provider. See
[Local API Integration Guide](docs/local-api-integration-guide.md).

## First Launch

1. Grant **Microphone** permission when prompted
2. Grant **Accessibility** permission (System Settings → Privacy & Security → Accessibility)
3. Choose a speech model to download:
   - **Qwen** — fast and quality local ASR options
   - **Whisper** — local English transcription through WhisperKit
   - **Parakeet** — local English and multilingual options through FluidAudio

Models are stored in `~/Library/Application Support/Hearsay/Models/`

## Requirements

- macOS 13.0 (Ventura) or later
- Works on both Apple Silicon and Intel Macs

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for build instructions and technical details.

## License

MIT
