#!/usr/bin/env python3
"""Post-hoc facial expression analysis for interview recordings.

Runs Py-Feat's detector over a recording at a sampled frame rate and writes a
JSON file with a timeline, aggregate statistics, and a compact human-readable
summary line intended for the AI feedback prompt.

Usage: facial_analysis.py video.mp4 --out video.faces.json [--fps 2] [--device auto]
"""

import argparse
import json
import math
import sys

RAD2DEG = 180.0 / math.pi

# Detectorv2 uses capitalized emotion columns; the classic stack uses lowercase.
EMOTION_COLUMN_SETS = [
    ["Anger", "Disgust", "Fear", "Happy", "Sad", "Surprise", "Neutral"],
    ["anger", "disgust", "fear", "happiness", "sadness", "surprise", "neutral"],
]

INTERPRETABLE_AUS = {
    "AU01": "inner brow raise",
    "AU02": "outer brow raise",
    "AU04": "brow furrow",
    "AU05": "upper lid raise",
    "AU06": "cheek raise",
    "AU07": "lid tighten",
    "AU09": "nose wrinkle",
    "AU10": "upper lip raise",
    "AU12": "smile",
    "AU14": "dimpler",
    "AU15": "lip corner depress",
    "AU17": "chin raise",
    "AU20": "lip stretch",
    "AU23": "lip tighten",
    "AU24": "lip press",
    "AU25": "lips part",
    "AU26": "jaw drop",
    "AU28": "lip suck",
    "AU43": "eyes closed",
}


def is_num(v):
    return v is not None and isinstance(v, (int, float)) and not (isinstance(v, float) and math.isnan(v))


def video_fps_and_frames(path):
    import cv2

    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    cap.release()
    if not fps or math.isnan(fps) or fps <= 0:
        fps = 30.0
    return fps, frames


def detect(path, skip, device):
    try:
        from feat import Detectorv2 as Det

        detector = Det(device=device)
        return detector.detect(path, data_type="video", skip_frames=skip, progress_bar=False)
    except ImportError:
        from feat import Detector

        detector = Detector(device=device)
        return detector.detect_video(path, skip_frames=skip)


def maybe_radians_to_degrees(values):
    """Detectorv2 reports pose/gaze in radians; the classic stack uses degrees."""
    finite = [abs(v) for v in values if is_num(v)]
    if finite and max(finite) < 3.5:
        return [v * RAD2DEG if is_num(v) else v for v in values]
    return values


def share_text(share):
    return ", ".join(f"{name} {round(frac * 100)}%" for name, frac in share)


def mean(vals):
    vals = [v for v in vals if is_num(v)]
    return sum(vals) / len(vals) if vals else None


def std(vals):
    vals = [v for v in vals if is_num(v)]
    if len(vals) < 2:
        return None
    m = sum(vals) / len(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--out", required=True)
    ap.add_argument("--fps", type=float, default=2.0, help="target sampled frames per second")
    ap.add_argument("--device", default="auto", choices=["auto", "cpu", "mps", "cuda"])
    args = ap.parse_args()

    fps, total_frames = video_fps_and_frames(args.video)
    skip = max(1, round(fps / args.fps))

    device = args.device
    if device == "auto":
        device = "cpu"
        try:
            import torch

            if torch.backends.mps.is_available():
                device = "mps"
        except Exception:
            pass

    try:
        fex = detect(args.video, skip, device)
    except Exception:
        if device != "cpu":
            device = "cpu"
            fex = detect(args.video, skip, device)
        else:
            raise

    emotion_cols = []
    for cols in EMOTION_COLUMN_SETS:
        present = [c for c in cols if c in fex.columns]
        if len(present) >= 5:
            emotion_cols = present
            break
    au_cols = sorted({c for c in fex.columns if len(c) == 4 and c.upper().startswith("AU")})
    pose_cols = [c for c in ["Pitch", "Roll", "Yaw"] if c in fex.columns]
    has_gaze = "gaze_angle" in fex.columns
    has_va = "valence" in fex.columns and "arousal" in fex.columns
    time_col = "approx_time" if "approx_time" in fex.columns else None

    # Convert pose and gaze radians to degrees when needed, column by column.
    converted = {}
    for c in pose_cols + (["gaze_angle", "gaze_pitch", "gaze_yaw"] if has_gaze else []):
        if c in fex.columns:
            converted[c] = maybe_radians_to_degrees(list(fex[c]))

    timeline = []
    for pos, (_, row) in enumerate(fex.iterrows()):
        frame = row.get("frame")
        if not is_num(frame):
            continue
        if time_col and is_num(row.get(time_col)):
            t = float(row[time_col])
        else:
            t = float(frame) / fps
        emotions = {}
        for c in emotion_cols:
            v = row.get(c)
            if is_num(v):
                emotions[c.lower()] = round(float(v), 3)
        if not emotions:
            continue
        dominant = max(emotions, key=emotions.get)
        aus = {c.upper(): round(float(row[c]), 3) for c in au_cols if is_num(row.get(c))}
        pose = {}
        for c in pose_cols:
            vals = converted.get(c)
            if vals is not None and pos < len(vals) and is_num(vals[pos]):
                pose[c.lower()] = round(vals[pos], 1)
        entry = {"t": round(t, 2), "dominant": dominant, "emotions": emotions, "aus": aus, "pose": pose}
        if has_gaze:
            g = converted.get("gaze_angle")
            if g is not None and pos < len(g) and is_num(g[pos]):
                entry["gaze_angle"] = round(g[pos], 1)
        if has_va:
            if is_num(row.get("valence")):
                entry["valence"] = round(float(row["valence"]), 3)
            if is_num(row.get("arousal")):
                entry["arousal"] = round(float(row["arousal"]), 3)
        timeline.append(entry)

    n = len(timeline)
    if n == 0:
        result = {
            "video": args.video,
            "device": device,
            "sampled_fps": round(fps / skip, 2),
            "frames_analyzed": 0,
            "face_detected_rate": 0.0,
            "summary_text": "No face detected in this recording.",
            "timeline": [],
        }
        with open(args.out, "w") as f:
            json.dump(result, f, indent=1)
        print("no face detected", file=sys.stderr)
        return

    sampled_total = max(1, total_frames // skip)
    face_rate = min(1.0, n / sampled_total)

    counts = {}
    for e in timeline:
        counts[e["dominant"]] = counts.get(e["dominant"], 0) + 1
    emotion_share = sorted(((k, v / n) for k, v in counts.items()), key=lambda kv: -kv[1])

    au_means = {}
    for au in au_cols:
        m = mean([e["aus"].get(au.upper()) for e in timeline])
        if m is not None:
            au_means[au.upper()] = round(m, 3)

    duration = timeline[-1]["t"] or 1.0
    thirds = []
    for i in range(3):
        lo, hi = duration * i / 3, duration * (i + 1) / 3
        seg = [e for e in timeline if lo <= e["t"] <= hi]
        if not seg:
            thirds.append("no face")
            continue
        seg_counts = {}
        for e in seg:
            seg_counts[e["dominant"]] = seg_counts.get(e["dominant"], 0) + 1
        top = sorted(seg_counts.items(), key=lambda kv: -kv[1])[:2]
        thirds.append("/".join(k for k, _ in top))

    head = {}
    for axis in ["yaw", "pitch"]:
        s = std([e["pose"].get(axis) for e in timeline])
        if s is not None:
            head[f"{axis}_std"] = round(s, 1)

    gaze = {}
    if has_gaze:
        angles = [e.get("gaze_angle") for e in timeline if is_num(e.get("gaze_angle"))]
        if angles:
            on_camera = sum(1 for a in angles if abs(a) <= 12) / len(angles)
            gaze = {"mean_angle": round(mean(angles), 1), "on_camera_share": round(on_camera, 3)}

    va = {}
    if has_va:
        vm = mean([e.get("valence") for e in timeline])
        am = mean([e.get("arousal") for e in timeline])
        if vm is not None:
            va["valence_mean"] = round(vm, 3)
        if am is not None:
            va["arousal_mean"] = round(am, 3)

    notable_aus = [
        f"{label} ({au}) {au_means[au]}"
        for au, label in INTERPRETABLE_AUS.items()
        if au in au_means and au_means[au] >= 0.3
    ]

    parts = [
        f"face visible {round(face_rate * 100)}% of frames",
        f"dominant expression: {share_text(emotion_share[:3])}",
        f"start/middle/end: {' -> '.join(thirds)}",
    ]
    if gaze:
        parts.append(f"gaze on camera {round(gaze['on_camera_share'] * 100)}% of frames")
    if va:
        parts.append(f"valence {va.get('valence_mean')}, arousal {va.get('arousal_mean')} (each -1 to 1)")
    if notable_aus:
        parts.append(f"notable muscle activity: {', '.join(notable_aus[:5])}")
    yaw_std = head.get("yaw_std")
    if yaw_std is not None:
        parts.append(f"head {'steady' if yaw_std < 6 else 'moving a lot'} (yaw std {yaw_std} deg)")
    summary_text = "; ".join(parts)

    result = {
        "video": args.video,
        "device": device,
        "sampled_fps": round(fps / skip, 2),
        "frames_analyzed": n,
        "face_detected_rate": round(face_rate, 3),
        "emotion_share": {k: round(v, 3) for k, v in emotion_share},
        "au_means": au_means,
        "thirds": thirds,
        "head": head,
        "gaze": gaze,
        "valence_arousal": va,
        "summary_text": summary_text,
        "timeline": timeline,
    }
    with open(args.out, "w") as f:
        json.dump(result, f, indent=1)
    print(summary_text)


if __name__ == "__main__":
    main()
