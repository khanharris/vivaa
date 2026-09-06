#!/usr/bin/env python3
"""Persistent live facial analysis for the Viva settings playground.

Loads Py-Feat once, then reads one JPEG path per stdin line and answers with
one JSON line per frame: emotion probabilities, dominant emotion, and the 68
facial landmarks in image pixel coordinates.
"""

import json
import sys


def emit(obj):
    print(json.dumps(obj), flush=True)


def main():
    device = "cpu"
    try:
        import torch

        if torch.backends.mps.is_available():
            device = "mps"
    except Exception:
        pass

    try:
        from feat import Detectorv2

        detector = Detectorv2(device=device)
    except Exception as e:
        emit({"ready": False, "error": str(e)})
        return

    import cv2

    emit({"ready": True, "device": device})

    emotion_cols = ["Anger", "Disgust", "Fear", "Happy", "Sad", "Surprise", "Neutral"]

    for line in sys.stdin:
        path = line.strip()
        if not path:
            continue
        try:
            img = cv2.imread(path)
            if img is None:
                emit({"ok": False})
                continue
            h, w = img.shape[:2]
            fex = detector.detect(path, data_type="image", progress_bar=False)
            if len(fex) == 0:
                emit({"ok": False})
                continue
            row = fex.iloc[0]
            emotions = {}
            for c in emotion_cols:
                if c in fex.columns:
                    v = row[c]
                    if v == v:
                        emotions[c.lower()] = round(float(v), 3)
            if not emotions:
                emit({"ok": False})
                continue
            landmarks = []
            for i in range(68):
                x = row.get(f"x_{i}")
                y = row.get(f"y_{i}")
                if x is not None and y is not None and x == x and y == y:
                    landmarks.append([round(float(x), 1), round(float(y), 1)])
            emit(
                {
                    "ok": True,
                    "dominant": max(emotions, key=emotions.get),
                    "emotions": emotions,
                    "landmarks": landmarks,
                    "w": w,
                    "h": h,
                }
            )
        except Exception as e:
            emit({"ok": False, "error": str(e)})


if __name__ == "__main__":
    main()
