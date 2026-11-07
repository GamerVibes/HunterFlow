"""Erzeugt die Effekttoene des Add-ons als OGG.

Aufruf: python tools/make_sounds.py
Braucht nur Python und ffmpeg im PATH. WoW laedt die Dateien aus dem Ordner Sounds.
"""
import math
import random
import struct
import subprocess
import tempfile
import wave
from pathlib import Path

RATE = 44100
OUT = Path(__file__).resolve().parent.parent / "Sounds"


def click(buffer, start, level, decay, tone=None, tone_level=0.0, tone_decay=0.02):
    """Knackiges Rauschen, optional mit einem kurzen Ton als Koerper."""
    begin = int(start * RATE)
    previous = 0.0
    for i in range(begin, len(buffer)):
        t = (i - begin) / RATE
        noise = random.uniform(-1, 1)
        bright = noise - previous  # einfacher Hochpass, macht es hell und trocken
        previous = noise
        value = bright * 0.5 * level * math.exp(-t / decay)
        if tone:
            value += math.sin(2 * math.pi * tone * t) * tone_level * math.exp(-t / tone_decay)
        buffer[i] += value


def ping(buffer, start, frequency, level, decay):
    """Heller, kurz ausklingender Ton."""
    begin = int(start * RATE)
    for i in range(begin, len(buffer)):
        t = (i - begin) / RATE
        attack = min(t / 0.002, 1)
        buffer[i] += math.sin(2 * math.pi * frequency * t) * level * attack * math.exp(-t / decay)


def lock_sound():
    """Einrasten: zwei trockene Klicks kurz hintereinander, mit etwas Tiefe."""
    buffer = [0.0] * int(0.09 * RATE)
    click(buffer, 0.0, 0.5, 0.004, tone=210, tone_level=0.45, tone_decay=0.012)
    click(buffer, 0.026, 0.8, 0.003, tone=420, tone_level=0.2, tone_decay=0.006)
    return buffer


def proc_sound():
    """Knacken beim perfekten Schuss: scharfer Knack, danach ein heller Nachklang."""
    buffer = [0.0] * int(0.32 * RATE)
    click(buffer, 0.0, 1.0, 0.003, tone=1300, tone_level=0.35, tone_decay=0.012)
    ping(buffer, 0.006, 1760, 0.22, 0.07)
    ping(buffer, 0.006, 2637, 0.16, 0.05)
    return buffer


def write_ogg(buffer, path, peak):
    """Normalisiert auf den Zielpegel und wandelt ueber eine WAV-Datei nach OGG."""
    loudest = max(abs(v) for v in buffer)
    samples = [round(v / loudest * peak * 32767) for v in buffer]
    with tempfile.TemporaryDirectory() as folder:
        temp = Path(folder) / "ton.wav"
        with wave.open(str(temp), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(struct.pack("<%dh" % len(samples), *samples))
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(temp), "-c:a", "libvorbis", "-q:a", "6", str(path)],
            check=True,
        )


if __name__ == "__main__":
    random.seed(75)  # gleiche Toene bei jedem Lauf
    OUT.mkdir(exist_ok=True)
    # WoW kann eigenen Toenen keine Lautstaerke mitgeben, daher eine Datei je Stufe.
    # Die volle Stufe hat keinen Zusatz im Namen, zum Beispiel Lock.ogg und Lock50.ogg.
    lock, proc = lock_sound(), proc_sound()
    for level in (100, 75, 50, 25):
        suffix = "" if level == 100 else str(level)
        write_ogg(lock, OUT / ("Lock%s.ogg" % suffix), 0.6 * level / 100)
        write_ogg(proc, OUT / ("Proc%s.ogg" % suffix), 0.8 * level / 100)
    print("Geschrieben nach", OUT)
