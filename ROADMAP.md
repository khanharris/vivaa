# Interview Prep App — Plan & Roadmap

An app for practicing recorded, asynchronous interviews in the multiple mini interview (MMI) format, with recording, AI feedback, and long-term progress tracking.

---

## The format being simulated

Recorded MMIs vary between programs, so the defaults below are what the app ships with rather than any one school's rules:

- **6 stations**, each a single question prompt
- **No separate reading time**: recording starts as soon as the question has been delivered, and thinking time counts within the answer time
- **Questions are delivered aloud**, since these interviews commonly present each prompt as a short video of an interviewer reading it. The app reads each question with the system voice and starts recording when it ends
- **5 minutes** to think and deliver a **recorded** response, with no live interviewer
- A **30-second gap** between stations
- Common themes: motivation for medicine, ethical dilemmas and situational judgment, teamwork, communication, public health

Because these interviews are *recorded to a webcam with no human present*, a solo practice app is an almost perfect simulation of the real thing, not just an approximation.

**Default session config:** 6 stations × 5 min answer + 5 × 30 s gaps ≈ **33 minutes**. All timings and station counts should be configurable so the app can adapt to other formats.

---

## Core features

### 1. Interview session engine
- Full-screen "exam mode" that walks through: the question read aloud → answer screen (camera on, 5:00 countdown) → break screen → next station
- Auto-advance exactly like the real thing — no pausing, no re-dos (with an optional "practice mode" that allows pause/retry for early prep)
- Visual + audio cues (30-second warning, etc.)

### 2. Custom question sets
- Upload/import your own question sets (start with a simple format: JSON or plain text/Markdown, one question per block; maybe CSV later)
- Tag questions by theme (ethics, motivation, teamwork, communication, public health…) — tags feed into stats and AI analysis
- Question set library: option to randomize station order or draw N random stations from the whole library, preferring ones not yet practised

### 3. Recording & storage
- Video + audio recording of each answer via webcam/mic
- User picks a destination folder on their computer; each session saves to a timestamped subfolder:
  ```
  /InterviewRecordings/2026-09-06_18-30-05/
    q1.mov ... q6.mov
    transcript.md
    summary.md
    session.json   (metadata: questions, timings, scores, emotion timeline)
  ```
- Everything stored locally — recordings never leave the machine unless a cloud AI step is explicitly used

### 4. AI transcription & analysis
- Transcribe audio per question (Whisper — either local `whisper.cpp` for privacy/free, or an API for simplicity)
- Since each question is a separate recording, transcripts are automatically separated by question — no need to split one long recording
- Analyze each answer against a framework, e.g.:
  - Structure (signposted intro → reasoning → balanced considerations → conclusion)
  - Ethics questions: principles-based reasoning (autonomy, beneficence, non-maleficence, justice), acknowledging both sides
  - Content relevance to the question actually asked
  - Delivery metrics from the transcript: words per minute, filler words ("um", "like", "you know"), answer length vs. the 5 minutes available, long silences
- Frameworks should be editable/pluggable (a Markdown or JSON rubric file) so you can tune them per question theme

### 5. Facial/mood analysis
- Run face analysis **locally**, never in the cloud
- Log an emotion/expression timeline per answer (e.g. neutral/confident/nervous/smiling at 1-second intervals), plus proxies like "looking at camera" %
- Timeline gets stored in `session.json` and fed into the AI summary ("you looked visibly tense during the ethics question, especially in the first minute")
- Treat this as *supporting signal*, not gospel — emotion detection is noisy, so the summary should phrase it as tendencies

### 6. AI session summary
- After each session, generate `summary.md` combining: the questions, transcripts, framework scores, delivery metrics, and the emotion timeline
- Format: overall impression → per-question feedback (strengths / weaknesses / a model answer outline) → top 3 things to work on next session

### 7. Statistics & consistency tracking
- **GitHub-style contribution heatmap** of practice days (the core "stay consistent" feature), with streak count
- Trends over time: average framework scores per theme, filler words per minute, WPM, answer duration, mood/confidence trend
- Per-theme breakdown so you can see e.g. "ethics questions are my weakest station type"
- All stats derived from stored `session.json` files, so history survives app updates

---

## Recommended tech stack

Since recordings must save to a local folder of your choice, this should be a **desktop app**:

| Layer | Choice | Why |
|---|---|---|
| Shell | **Swift + SwiftUI** | Native macOS app, one ~5 MB binary, no web runtime |
| Recording | **AVFoundation** (`AVCaptureMovieFileOutput`) | Hardware-encoded 1080p H.264/AAC straight to `.mov` |
| Question delivery | **AVSpeechSynthesizer** | Reads each station aloud, standing in for the interviewer video |
| Transcription | **whisper.cpp**, bundled | Local, free, private; no API key and no network |
| Face analysis | **Py-Feat** via a subprocess | Full research stack: emotions, FACS action units, head pose |
| AI feedback | **Claude Code CLI** (Opus 5) or **Codex CLI** | Uses an existing subscription login; only transcript text leaves the Mac |
| Storage | Plain JSON + Markdown per session folder | Human-readable, portable, easy stats, survives app updates |

---

## Roadmap

### Phase 1 — Core interview loop (MVP) ✅
The app is already useful with just this.
- [x] SwiftUI app scaffold
- [x] Session engine: reading → answer → break flow with timers, auto-advance (plus skip buttons)
- [x] Webcam/mic recording (H.264 `.mov`), saved per-station to a chosen folder
- [x] Session metadata saved (`session.json`)
- [x] Camera and microphone test, with input selection (built-in mic by default)

### Phase 2 — Custom questions & review
- [x] Question set import (JSON), theme tagging
- [ ] Session history screen: past-session list shipped (analyze/view summary/open folder); in-app video replay still to do
- [x] Recorded MMI format: 6 stations, question read aloud, 5:00 to think and answer
- [ ] Configurable format (station count, timings) in the UI — currently code constants

### Phase 3 — Transcription & AI feedback ✅ (first version)
- [x] Whisper transcription per station → `transcript.md` (bundled whisper.cpp, large-v3 model)
- [x] Delivery metrics (WPM, filler words) — silence detection still to do
- [x] Framework-based analysis with editable rubric (`rubric.md` in app data folder)
- [x] `summary.md` generation, shown in-app after each session
- [x] Automatic hand-off to Claude Code CLI (subscription auth, Opus 5 max effort) — no API key needed; requires one-time `claude` login

### Phase 4 — Statistics ✅ (first version)
- [x] GitHub-style practice heatmap (26 weeks) + current/longest streaks
- [x] Stat tiles: sessions, answers recorded, total answering time
- [x] Per-theme average scores (parsed from AI summaries; new summaries embed a machine-readable score block)
- [x] Recent sessions with average scores
- [ ] Metric trends over time (WPM/filler trends across sessions)

### Phase 5 — Facial analysis ✅ (first version)
- [x] Post-hoc analysis with Py-Feat (chosen over real-time MediaPipe for accuracy: full research stack, emotions + FACS action units + head pose)
- [x] Per-question `qN.faces.json` (sampled timeline + aggregates) saved in the session folder
- [x] Facial cues fed into the AI summary with guardrails (tendencies, not facts)
- [x] Settings toggle; degrades gracefully if the Python env is missing
- [ ] Emotion timeline visualization synced to video playback

### Ideas
- Live facial overlay during recording: the Settings playground (realtime emotion reading + landmark dots) could run during answers if the frame rate and distraction factor prove acceptable.

### Phase 6 — Polish & stretch
- [ ] Transcript synced to video playback (click a sentence → jump to that moment)
- [ ] "Weak spot" drills: auto-build a session from your worst-scoring themes
- [ ] Model answer generation per question
- [ ] Export a session report (PDF) for a tutor/mentor to review
- [ ] Presets for other schools' formats (standard MMI, panel, etc.)

---

## Suggested additions (beyond your list)

1. **Practice mode vs. exam mode** — early on you'll want to pause, re-record, or skip; closer to the date you want the unforgiving real format. A single toggle covers both.
2. **Delivery metrics** (filler words, pace, silence, looking-at-camera %) — cheap to compute and often more actionable than content feedback.
3. **Streak-aware nudges** — the heatmap is more motivating with a streak counter and maybe a daily reminder.
4. **Offline-first analysis queue** — record without internet; transcription/AI runs when you're back online, so a flaky connection never kills a session.
5. **Answer-to-model-answer comparison** — after your attempt, see an AI model answer outline for the same question and a diff of what you covered vs. missed.
6. **Warm-up question** — the real thing is nerve-wracking from question 1; an optional throwaway warm-up question mimics settling in.
7. **Privacy stance as a feature** — all video stays local, only text transcripts go to the AI API (and even that can be local later). Worth stating in the app.
