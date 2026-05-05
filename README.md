# dwr — Daily Work Capture System

Local-only screen + audio capture and indexing for macOS. Records active-window
screenshots and microphone audio, OCRs / transcribes them with Apple's Vision
and Speech frameworks, and appends timestamped entries to per-day Markdown
logs. Nothing leaves the machine.

The full spec is in [BASIC.md](BASIC.md).

## How it works

Four LaunchAgents drive the pipeline:

| Service | Trigger | Output |
|---|---|---|
| `image-capture` | every 5 seconds | active-window PNG → `~/capture/image/incoming/` |
| `image-ocr` | when `incoming/` changes | OCR text appended to `~/capture/text/image/YYYY-MM-DD.md` |
| `audio-capture` | continuous | speech-segmented WAV → `~/capture/audio/incoming/` |
| `audio-transcribe` | when `incoming/` changes | transcript appended to `~/capture/text/audio/YYYY-MM-DD.md` |

OCR uses [Vision.framework's `VNRecognizeTextRequest`](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
(ja-JP + en-US). Transcription uses [Speech.framework's `SFSpeechRecognizer`](https://developer.apple.com/documentation/speech/sfspeechrecognizer)
in on-device mode. Audio capture is built on `ffmpeg`'s `avfoundation` input,
with `silenceremove` for leading-silence trim and `silencedetect` (parsed from
stderr) to terminate ffmpeg on 2 s of trailing silence.

## Requirements

- macOS 13 (Ventura) or later — built and tested on macOS 15 (Sequoia)
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`)
- A microphone

## Install

```bash
git clone https://github.com/goofmint/dwr.git
cd dwr
./setup.sh
```

This installs `ffmpeg` and `imagemagick` via Homebrew, builds the two Swift
CLIs (`ocr-cli`, `transcribe-cli`), creates `~/capture/`, generates the four
LaunchAgent plists from the templates in [launchd/](launchd/), and bootstraps
them with `launchctl`. It is re-runnable: existing jobs are booted out before
being re-bootstrapped.

After the script finishes, the system is loaded but not yet useful — finish the
manual steps below.

## Manual setup

### 1. Privacy permissions

System Settings → Privacy & Security:

| Permission | Granted to |
|---|---|
| Screen Recording | the process that runs the launchd job |
| Microphone | same |
| Speech Recognition | `transcribe-cli` (prompted on first launch) |

Plus enable **Siri OR Dictation** (System Settings → Apple Intelligence & Siri,
or → Keyboard → Dictation, with **日本語** in languages). The Speech framework's
on-device path requires one of these — without it, transcription fails with
`Siri and Dictation are disabled`.

### 2. Audio device

```bash
bin/configure.sh
```

The wizard lists CoreAudio input devices (default marked with `*`), captures
silence threshold and segment cap, and writes `~/.config/dwr/config.toml`.
Manual editing is supported too — see [config.sample.toml](config.sample.toml).

When the configured device is unplugged at runtime, `audio-capture.sh`
transparently falls back to the current system default and switches back when
the device returns.

### 3. (Optional) System audio capture

To record system audio (the other side of a call) along with your mic, install
[BlackHole](https://github.com/ExistentialAudio/BlackHole) and configure a
Multi-Output + Aggregate Device pair manually in **Audio MIDI 設定.app**. GUI
automation isn't possible — Audio MIDI Setup has poor AppleScript coverage.

```bash
brew install --cask blackhole-2ch
# log out / in if BlackHole isn't visible yet
```

```text
[system audio]              [mic e.g. Yeti]
       ↓                          ↓
[Multi-Output Device]      [Aggregate Device]
  ├─ Speakers                ├─ Yeti
  └─ BlackHole 2ch ──────→   └─ BlackHole 2ch
                                   ↓
                          ffmpeg reads from here
```

Steps:

1. **Multi-Output Device** so system audio goes to BlackHole *and* your speakers
    - + → `Create Multi-Output Device`
    - check your usual output (Speakers / Headphones) and `BlackHole 2ch`
    - set "マスタデバイス" (Master Device) to your usual output (clock source)
    - rename, e.g. `dwr-output`
2. **Aggregate Device** so ffmpeg sees mic + BlackHole as a single input
    - + → `Create Aggregate Device`
    - check your mic and `BlackHole 2ch`
    - set "マスタデバイス" to `BlackHole 2ch` (avoid clock drift)
    - rename, e.g. `dwr-input`
3. **System Settings → Sound**
    - Output: `dwr-output`
    - Input: `dwr-input`
4. Re-run `bin/configure.sh` and pick `dwr-input`.

## Configuration

`~/.config/dwr/config.toml` (managed by `bin/configure.sh`):

```toml
audio_input_device = "Yeti Stereo Microphone"
silence_threshold  = "-40dB"   # ffmpeg silenceremove threshold
max_segment_sec    = 60        # hard cap per audio segment
```

Environment variables of the same uppercase name override the config file.

## Layout

```
~/capture/
├── image/
│   ├── incoming/          # active-window PNGs queued for OCR
│   └── processed/         # post-OCR archive
├── audio/
│   ├── incoming/          # speech-segmented WAVs queued for transcribe
│   └── processed/         # post-transcribe archive
├── text/
│   ├── image/YYYY-MM-DD.md   # OCR transcripts
│   └── audio/YYYY-MM-DD.md   # speech transcripts
└── state/
    ├── *.log              # per-service launchd stdout/stderr
    ├── last-frame-d*.png  # image-capture dedup state
    └── display-info       # cached menu-bar heights per display
```

## Verifying it works

```bash
launchctl list | grep goofmint     # 4 entries, all with a real PID

ls ~/capture/image/incoming/        # PNGs queued, draining as image-ocr runs
ls ~/capture/audio/incoming/        # WAVs queued, draining as audio-transcribe runs

cat ~/capture/text/image/$(date +%Y-%m-%d).md
cat ~/capture/text/audio/$(date +%Y-%m-%d).md
```

Tail the per-service logs:

```bash
tail -f ~/capture/state/audio-capture.log
tail -f ~/capture/state/image-ocr.log
```

For verbose `audio-capture` state-transition logs, set `DWR_DEBUG=1` in the
plist's `EnvironmentVariables` and reload the job. `launchctl kickstart -k`
only restarts the service launchd already has in memory; to pick up plist
edits the job has to be unloaded and re-bootstrapped from the file:

```bash
launchctl bootout gui/$(id -u)/dev.goofmint.dw.audio-capture
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.goofmint.dw.audio-capture.plist
```

## Maintenance

There is no automatic cleanup. To prune originals older than 30 days while
keeping the markdown transcripts:

```bash
find ~/capture/image/processed -name '*.png' -mtime +30 -delete
find ~/capture/audio/processed -name '*.wav' -mtime +30 -delete
```

## Troubleshooting

- **Empty markdown files.** Permissions are usually missing. Re-check Screen
  Recording / Microphone / Speech Recognition for the relevant process and run
  `launchctl kickstart -k gui/$(id -u)/dev.goofmint.dw.<service>` to retry.
- **`audio-capture` logs `Siri and Dictation are disabled`.** Enable Siri or
  Dictation (with 日本語) in System Settings as described above.
- **`audio-capture` won't fall back when the configured mic disappears.** Run
  with `DWR_DEBUG=1` and inspect the log; the script polls the device list
  every 5 seconds and escalates SIGINT → SIGKILL after 1 s if `ffmpeg` is wedged.
- **`image-capture` shows over-cropped screenshots.** The script reads the live
  menu-bar heights from WindowServer; if they get stale, delete
  `~/capture/state/display-info` and the next tick will re-detect.

## Uninstall

```bash
./uninstall.sh
```

Stops the four launchd jobs, removes the plists from `~/Library/LaunchAgents/`,
and unlinks `~/.local/bin/dw-{ocr,transcribe}-cli`. **User data
(`~/capture/`, `~/.config/dwr/`) is preserved.**

To wipe everything:

```bash
./uninstall.sh
rm -rf ~/capture ~/.config/dwr
```
