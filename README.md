# Viva

Practice for **recorded, asynchronous interviews**, the multiple mini interview format used by medical and other graduate programs. A session runs 6 stations by default: each question is read aloud, then you have 5:00 to think and answer on camera, with a short break before the next one.

A native SwiftUI and AVFoundation macOS app, about 5 MB. Recording, transcription and facial analysis all run on your Mac; only the text of your answers is ever sent anywhere, and only when you ask for feedback. See [ROADMAP.md](ROADMAP.md) for the plan.

## Build and install

Requires the Xcode Command Line Tools (`swiftc`) and Homebrew `whisper-cpp`, which the build bundles into the app so recipients need no Homebrew of their own.

```bash
./build.sh && rm -rf /Applications/Viva.app && cp -R dist/Viva.app /Applications/
```

First launch asks for camera and microphone access. Choose a recordings folder, pick a question set and start a session. **Quick test mode** in Settings shortens the timers so you can try the whole flow in a couple of minutes.

## How a session runs

Each station opens with the question on screen while the system voice reads it aloud, standing in for the interviewer video in the real interview. Recording starts the moment the reading ends, and thinking time counts toward your 5 minutes. Turn the reading off under Settings, Question delivery.

Bluetooth headphones drop to a low-quality headset profile whenever their microphone is in use, which also degrades what you hear, so Viva records from the Mac's built-in microphone by default. Pick a different input under Settings, Camera and microphone.

## What gets saved

Each session creates a timestamped folder inside your recordings folder:

```
2026-09-06_18-30-05/
  q1.mov … q6.mov      one video per station (H.264/AAC, hardware encoded)
  session.json         questions, themes, timings, durations
  transcript.md        local Whisper transcript with delivery metrics (after analysis)
  summary.md           AI feedback with per-station scores (after analysis)
  qN.faces.json        facial cues per station (when facial analysis is on)
```

App data (settings, speech models, question sets, rubric) lives in `~/Library/Application Support/interviewapp/`.

## Question sets

Sets are JSON files in `~/Library/Application Support/interviewapp/question-sets/`, listed in the picker in filename order. Import one with **Import question set (JSON)…** in Settings, or drop a file into that folder and relaunch. A station can carry several prompts on separate lines, and each is read aloud in turn.

```json
{
  "name": "My Question Set",
  "questions": [
    { "text": "Why medicine?", "theme": "motivation" },
    { "text": "A patient refuses treatment. What do you do?\nDescribe a time your values were challenged.", "theme": "ethics" }
  ]
}
```

`theme` is optional and feeds the statistics and the AI feedback.

## Analysis and feedback

After a session the app transcribes each answer with the bundled whisper.cpp, optionally runs facial analysis with [Py-Feat](https://py-feat.org/), then sends the transcripts (text only, never video) to Claude Opus 5 through the Claude Code CLI, or to ChatGPT through the Codex CLI. The Settings tab has one-click installs for the speech model, the facial analysis engine and both CLIs, plus a connection test.

The rubric the coach marks against lives at `~/Library/Application Support/interviewapp/rubric.md` and is yours to edit. Feedback needs a logged-in CLI: run `claude` then `/login`, or `codex login`, once in Terminal.

## Notes and troubleshooting

- Audio extraction for Whisper uses macOS's built-in `afconvert`, so no ffmpeg is bundled.
- The facial analysis script ships inside the app bundle; its Python environment stays in the app data folder.
- **Camera prompt returns after a rebuild:** builds are ad-hoc signed, so macOS may ask for camera and microphone access again. Accept the prompt, or re-enable Viva under System Settings, Privacy and Security.
- **Black video with audio:** macOS grants camera access to the app that launched the process. Launch Viva from Finder or the Dock rather than from another tool.
- **The reading voice sounds robotic:** the app picks the best installed English voice, preferring your own region. Download an Enhanced or Premium voice under System Settings, Accessibility, Spoken Content, Manage Voices, and it will be used on next launch. Settings has a Preview voice button.
