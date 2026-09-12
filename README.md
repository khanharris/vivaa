# Viva

Practice for **recorded, asynchronous interviews**, the multiple mini interview format used by medical and other graduate programs. A session runs 6 stations back to back by default, with no break: each question is read aloud with the prompt on screen, then the prompt disappears and you have 5:00 to think and answer on camera.

A native SwiftUI and AVFoundation macOS app, about 5 MB. Recording, transcription and facial analysis all run on your Mac; only the text of your answers is ever sent anywhere, and only when you ask for feedback. See [ROADMAP.md](ROADMAP.md) for the plan.

## Build and install

Requires Xcode or the Xcode Command Line Tools, and Homebrew `whisper-cpp`, which the build bundles into the app so recipients need no Homebrew of their own. Command Line Tools 27 and later lack the SwiftUI macro plugin, so the build script uses Xcode's toolchain whenever Xcode is installed.

```bash
./build.sh && rm -rf /Applications/Viva.app && cp -R dist/Viva.app /Applications/
```

First launch asks for camera and microphone access. Choose a recordings folder, pick a question set and start a session. The picker beneath the set runs the whole set or just one station from it, so you can drill a single question without sitting a full session. **Quick test mode** in Settings shortens the timers so you can try the whole flow in a couple of minutes.

## How a session runs

Each station opens with the question on screen while the system voice reads it aloud, standing in for the interviewer video in a real recorded interview. Recording starts the moment the reading ends and the prompt leaves the screen, so you answer from memory as you would on the day; thinking time counts toward your 5 minutes. The next station begins as soon as the answer stops recording. Turn the reading off under Settings, Question delivery.

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

## Session video

**Make video** on any session in the Statistics tab stitches that session into one continuous `session-video.mp4` in the session folder. Because the question is read aloud before recording starts, it exists in no recording, so each station gets a generated title card showing the prompt with the same synthesized voice speaking it, spliced in front of the answer. Expect roughly the size of the session's own recordings, and a few minutes to encode.

## Coaching review

A single session's feedback can only see that session. The **Coaching review** on the Statistics tab reads every analyzed session at once, oldest first, and looks for what one session cannot show: the habits that keep recurring, whether advice from an earlier session was actually acted on later, which station types are weakest and why, and how pace, filler words and time use are trending.

It needs at least two analyzed sessions. The result is saved as `coaching-review.md` at the top of your recordings folder and shown in the app. Press **Update review** after new sessions to regenerate it. Recent sessions contribute their full transcripts as evidence; older ones contribute their metrics and the feedback they were given, so the review keeps working as the history grows.

## Notes and troubleshooting

- Audio extraction for Whisper uses macOS's built-in `afconvert`, so no ffmpeg is bundled.
- The facial analysis script ships inside the app bundle; its Python environment stays in the app data folder.
- **Camera prompt returns after a rebuild:** builds are ad-hoc signed, so macOS may ask for camera and microphone access again. Accept the prompt, or re-enable Viva under System Settings, Privacy and Security.
- **Feedback says you repeated one sentence for minutes, but the recording shows you talking normally:** older builds let the transcriber feed each 30-second window its own previous output, which could lock it into a loop. That is fixed; press Re-analyze on the affected session to regenerate its transcript and feedback.
- **Black video with audio:** macOS grants camera access to the app that launched the process. Launch Viva from Finder or the Dock rather than from another tool.
- **The reading voice sounds robotic:** the app picks the best installed English voice, preferring your own region. Download an Enhanced or Premium voice under System Settings, Accessibility, Spoken Content, Manage Voices, and it will be used on next launch. Settings has a Preview voice button.
