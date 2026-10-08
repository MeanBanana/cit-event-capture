"""
audio.py - listens to a video's sound for GUNFIRE and EXPLOSIONS, and works
out from the timing of the shots whether the fire sounds AUTOMATIC or
SEMI-AUTOMATIC.

How it works, in plain English:

  1. The sound is taken out of the video (ffmpeg, bundled with the
     imageio-ffmpeg package - nothing to install separately).
  2. YAMNet, Google's free sound-recognition model (521 everyday sounds,
     trained on Google's AudioSet), scores every half second of sound for
     "Gunshot, gunfire", "Machine gun", "Explosion", "Fireworks", ...
     Parts that sound like gunfire or an explosion become EVENTS.
  3. Inside each gunfire event we find every individual BANG (a very sudden
     jump in loudness) and measure the gaps between them:
       * automatic fire: the gun's mechanism sets the rhythm, so the bangs
         are close together (about 0.05-0.14 s, i.e. 450-1200 rounds a
         minute) and very evenly spaced - at least 4 in a row
       * semi-automatic: one trigger pull per shot, so the gaps are longer
         (usually 0.15 s or more) and uneven
       * anything else is reported as "unclear" rather than guessed
     Timing is used instead of "what does the gun sound like" because phone
     microphones distort loud bangs and WhatsApp compresses the sound, but
     WHEN each bang happens survives both.

Honest limits (investigators see these as leads, not proof):
  * echoes off buildings can add extra "bangs": bangs much quieter than the
    shot just before them are treated as echoes, and mixed rhythms come out
    as "unclear" rather than wrong
  * gun HANDLING (loading, cocking) makes metal clicks that the sound model
    can mistake for shots: clicks die away much faster than a gunshot rings
    on, so they aren't counted as shots (could_be_handling flags it)
  * fireworks, firecrackers, a car backfiring or a door slam can sound like
    shots: every event also reports the fireworks score so it can be checked
  * an automatic weapon fired one shot at a time sounds like semi-automatic

YAMNet: Apache 2.0, (c) Google, https://github.com/tensorflow/models/tree/master/research/audioset/yamnet
Converted to ONNX for this project (so no TensorFlow is needed); the sound
preparation below copies YAMNet's own exactly (checked to 0.0001 against the
TensorFlow original). Files in audio_models/.
"""

import subprocess
from pathlib import Path

import numpy as np

MODELS = Path(__file__).parent / "audio_models"
YAMNET_MODEL = MODELS / "yamnet.onnx"
YAMNET_LABELS = MODELS / "yamnet_class_map.csv"

SAMPLE_RATE = 16000

# YAMNet class names we use (from yamnet_class_map.csv)
GUN_CLASSES = ["Gunshot, gunfire", "Machine gun", "Fusillade", "Artillery fire", "Cap gun"]
EXPLOSION_CLASSES = ["Explosion", "Boom"]
LOOK_ALIKE_CLASSES = ["Fireworks", "Firecracker"]

# Shot timing rules (seconds between bangs)
MIN_GAP = 0.05          # faster than ~1200 rounds/min: same bang (or its echo)
AUTO_MAX_GAP = 0.14     # automatic: 450+ rounds/min
SEMI_MIN_GAP = 0.15     # semi-automatic: separate trigger pulls
AUTO_MAX_UNEVENNESS = 0.25   # automatic gaps vary by under 25%


# ---------------------------------------------------------------------------
# Getting the sound out of the video
# ---------------------------------------------------------------------------

def load_audio(path, sample_rate=SAMPLE_RATE):
    """The video's sound as mono float32 samples (-1..1) at `sample_rate`,
    or None if the file has no sound."""
    import imageio_ffmpeg
    command = [imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-v", "error",
               "-i", str(path), "-vn", "-ac", "1", "-ar", str(sample_rate),
               "-f", "f32le", "-"]
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0 or not result.stdout:
        return None                      # no sound track (or unreadable)
    return np.frombuffer(result.stdout, dtype=np.float32).copy()


# ---------------------------------------------------------------------------
# YAMNet (sound recognition)
# ---------------------------------------------------------------------------

# Sound preparation, exactly as YAMNet's features.py: 25 ms windows every
# 10 ms -> 64 mel bands (125-7500 Hz) -> log -> 0.96 s patches every 0.48 s.
_WIN, _HOP, _NFFT, _MELS = 400, 160, 512, 64
PATCH_FRAMES, PATCH_HOP_FRAMES = 96, 48
PATCH_SECONDS, PATCH_HOP_SECONDS = 0.96, 0.48


def _mel_matrix(fmin=125.0, fmax=7500.0):
    def hz_to_mel(f):
        return 1127.0 * np.log1p(np.asarray(f, np.float64) / 700.0)
    freqs = np.linspace(0.0, SAMPLE_RATE / 2, _NFFT // 2 + 1)[1:]
    mel = hz_to_mel(freqs)[:, None]
    edges = np.linspace(hz_to_mel(fmin), hz_to_mel(fmax), _MELS + 2)
    lower, centre, upper = edges[:-2], edges[1:-1], edges[2:]
    weights = np.maximum(0.0, np.minimum((mel - lower) / (centre - lower),
                                         (upper - mel) / (upper - centre)))
    return np.vstack([np.zeros((1, _MELS)), weights]).astype(np.float32)


_MEL = _mel_matrix()
_WINDOW = (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(_WIN) / _WIN)).astype(np.float32)


def _pad(wave):
    """Pads with silence to a whole number of patches (YAMNet's pad_waveform)."""
    min_samples = int((PATCH_SECONDS + 0.025 - 0.010) * SAMPLE_RATE)
    n = len(wave)
    padding = max(0, min_samples - n)
    n = max(n, min_samples)
    hop = int(PATCH_HOP_SECONDS * SAMPLE_RATE)
    extra = n - min_samples
    padding += hop * int(np.ceil(extra / hop)) - extra
    return np.pad(wave, (0, padding))


def log_mel_patches(wave):
    """(patches, 96, 64) YAMNet input for a 16 kHz mono wave."""
    wave = _pad(np.asarray(wave, np.float32))
    frames = 1 + (len(wave) - _WIN) // _HOP
    index = np.arange(_WIN)[None, :] + _HOP * np.arange(frames)[:, None]
    magnitude = np.abs(np.fft.rfft(wave[index] * _WINDOW, n=_NFFT, axis=1)).astype(np.float32)
    log_mel = np.log(magnitude @ _MEL + 0.001)
    patches = 1 + (len(log_mel) - PATCH_FRAMES) // PATCH_HOP_FRAMES
    index = np.arange(PATCH_FRAMES)[None, :] + PATCH_HOP_FRAMES * np.arange(patches)[:, None]
    return log_mel[index]


class SoundTagger:
    """Scores every 0.48 s of sound for YAMNet's 521 sound classes."""

    def __init__(self, model=YAMNET_MODEL, labels=YAMNET_LABELS):
        import csv
        import onnxruntime as ort
        self.session = ort.InferenceSession(str(model), providers=["CPUExecutionProvider"])
        self.input_name = self.session.get_inputs()[0].name
        with open(labels, newline="", encoding="utf-8") as f:
            rows = list(csv.reader(f))[1:]
        self.labels = [name for _, _, name in rows]
        self.index = {name: i for i, name in enumerate(self.labels)}

    def scores(self, wave, batch=64):
        """(patches, 521) scores 0-1. Patch i covers i*0.48 s to i*0.48+0.96 s."""
        patches = log_mel_patches(wave)
        out = [self.session.run(None, {self.input_name: patches[i:i + batch]})[0]
               for i in range(0, len(patches), batch)]
        return np.concatenate(out) if out else np.zeros((0, len(self.labels)), np.float32)

    def columns(self, names):
        return [self.index[n] for n in names]


# ---------------------------------------------------------------------------
# Finding individual bangs + reading the rhythm
# ---------------------------------------------------------------------------

def find_bangs(wave, start, end, frame_ms=2, rise_db=4.0, window_db=20.0,
               look_back=0.03, echo_db=4.0, echo_window=0.5, max_tail_drop=28.0):
    """The GUNSHOTS between `start` and `end`: (shot times in seconds,
    number of short clicks/knocks that were NOT counted as shots).

    1. A bang = the loudness (above 500 Hz, to ignore wind and engine rumble)
       jumps by at least `rise_db` compared to the quietest moment in the
       previous `look_back` seconds, and is within `window_db` of the loudest
       bang in the stretch. Bangs closer than MIN_GAP are one bang.
    2. ECHOES are dropped: a bang at least `echo_db` quieter than a bang in
       the previous `echo_window` seconds. (On our real test clips every echo
       was 5-12 dB quieter than its shot - e.g. a range's back wall echoes
       0.15 s later - while shots in a burst stay about equally loud.)
    3. CLICKS are dropped: a gunshot rings on - 50-250 ms later it is only
       about 17-20 dB quieter (measured on real rifle and pistol clips). A
       click or knock (loading, cocking, a door) dies away: 35-50 dB quieter.
       Bangs whose sound drops more than `max_tail_drop` dB don't count.
    """
    from scipy.signal import butter, sosfilt
    total = len(wave) / SAMPLE_RATE
    a = int(max(0, start) * SAMPLE_RATE)
    b = int(min(total, end + 0.3) * SAMPLE_RATE)       # + room to hear the ring-out
    piece = wave[a:b]
    step = int(SAMPLE_RATE * frame_ms / 1000)
    if len(piece) < step * 10:
        return [], 0
    piece = sosfilt(butter(4, 500, "highpass", fs=SAMPLE_RATE, output="sos"), piece)
    frames = len(piece) // step
    rms = np.sqrt(np.mean(piece[:frames * step].reshape(frames, step) ** 2, axis=1))
    loud = 20 * np.log10(rms + 1e-7)
    last = min(frames, int((end - start) * 1000 / frame_ms) + 1)   # bangs only up to `end`

    back = max(1, int(look_back * 1000 / frame_ms))
    floor = np.array([loud[max(0, i - back):i].min() if i else loud[0] for i in range(frames)])
    rise = loud - floor
    loudest = loud[:last].max()

    candidates = [i for i in range(1, min(last, frames - 1))
                  if rise[i] >= rise_db and loud[i] >= loudest - window_db
                  and loud[i] >= loud[i - 1] and loud[i] >= loud[i + 1]]
    min_frames = int(MIN_GAP * 1000 / frame_ms)
    bangs = []
    for i in candidates:
        if bangs and i - bangs[-1] < min_frames:
            if loud[i] > loud[bangs[-1]]:
                bangs[-1] = i            # same bang: keep the loudest moment
            continue
        bangs.append(i)

    def peak(i):
        return loud[i:i + 5].max()

    # 2. echoes: much quieter than a bang shortly before it
    window = int(echo_window * 1000 / frame_ms)
    kept = []
    for i in bangs:
        recent = [peak(j) for j in kept if i - j <= window]
        if recent and peak(i) <= max(recent) - echo_db:
            continue
        kept.append(i)

    # 3. clicks: the sound dies away too fast to be a gunshot
    t50, t250 = int(50 / frame_ms), int(250 / frame_ms)
    shots, clicks = [], 0
    for i in kept:
        tail = loud[i + t50:i + t250]
        if len(tail) and peak(i) - np.median(tail) > max_tail_drop:
            clicks += 1
            continue
        shots.append(i)
    return [round(start + i * frame_ms / 1000, 3) for i in shots], clicks


def _regular_run(gaps):
    """The longest run of consecutive gaps that look like automatic fire
    (each 0.05-0.14 s). Returns that run as a list."""
    best, run = [], []
    for gap in gaps:
        if MIN_GAP <= gap <= AUTO_MAX_GAP:
            run.append(gap)
            best = run if len(run) > len(best) else best
        else:
            run = []
    return list(best)


def fire_mode(shot_times):
    """Reads the rhythm of a group of bangs.

    Returns (mode, note, details):
      "automatic"          4+ bangs in a row 0.05-0.14 s apart, evenly spaced
                           (3 is too easily faked by a shot + 2 echoes)
      "semi_automatic_or_single_shots"
                           2+ bangs, typically 0.15 s or more apart
      "single_shot"        one bang
      "unclear"            anything else (e.g. echoes, mixed rhythms)
    """
    n = len(shot_times)
    if n == 0:
        return "unclear", "no clear individual bangs found", {}
    if n == 1:
        return "single_shot", "one bang", {}
    gaps = np.diff(shot_times)
    details = {"median_gap_seconds": round(float(np.median(gaps)), 3)}

    run = _regular_run(gaps)
    if len(run) >= 3:                      # 4+ bangs in a row
        mean = float(np.mean(run))
        unevenness = float(np.std(run) / mean)
        details.update(rounds_per_minute=int(round(60 / mean)),
                       unevenness=round(unevenness, 2),
                       auto_run_shots=len(run) + 1)
        if unevenness <= AUTO_MAX_UNEVENNESS:
            return ("automatic",
                    f"{len(run) + 1} bangs {mean:.3f} s apart, evenly spaced "
                    f"(about {int(round(60 / mean))} rounds/min)", details)
        return ("unclear", "bangs close together but unevenly spaced "
                "(could be echoes or several shooters)", details)

    if np.median(gaps) >= SEMI_MIN_GAP:
        return ("semi_automatic_or_single_shots",
                f"{n} bangs about {np.median(gaps):.2f} s apart: separate trigger "
                "pulls (semi-automatic, or an automatic weapon fired one shot at a time)",
                details)
    return "unclear", "rhythm doesn't clearly fit automatic or semi-automatic", details


# ---------------------------------------------------------------------------
# The whole analysis
# ---------------------------------------------------------------------------

class AudioAnalyser:
    """Finds gunfire and explosion events in a video's sound."""

    version = "yamnet-onnx"

    def __init__(self):
        self.tagger = SoundTagger()
        self.gun_cols = self.tagger.columns(GUN_CLASSES)
        self.explosion_cols = self.tagger.columns(EXPLOSION_CLASSES)
        self.look_alike_cols = self.tagger.columns(LOOK_ALIKE_CLASSES)

    def analyse(self, video_path, min_score=0.25, burst_gap=1.0):
        """{"audio_available": bool, "audio_events": [...]} for a video.

        min_score  how sure YAMNet must be (0-1) for a stretch of sound to
                   count as gunfire / an explosion. Lower = finds more, but
                   more false alarms.
        burst_gap  bangs further apart than this (seconds) are separate groups.
        """
        wave = load_audio(video_path)
        if wave is None or len(wave) < SAMPLE_RATE * 0.2:
            return {"audio_available": False, "audio_events": []}
        scores = self.tagger.scores(wave)
        duration = len(wave) / SAMPLE_RATE

        gun = scores[:, self.gun_cols].max(axis=1)
        boom = scores[:, self.explosion_cols].max(axis=1)

        # Stretches of sound that are gunfire OR an explosion. A gunshot also
        # sounds a lot like an explosion (YAMNet often gives both a high
        # score), so each stretch is judged as a whole: gunfire unless it
        # sounds clearly MORE like an explosion than like gunfire.
        events = []
        for first, last, _ in self._stretches(np.maximum(gun, boom), min_score):
            gun_peak = float(gun[first:last + 1].max())
            boom_peak = float(boom[first:last + 1].max())
            if gun_peak >= min_score and gun_peak >= 0.6 * boom_peak:
                kind, cols, peak = "gunfire", self.gun_cols, gun_peak
            else:
                kind, cols, peak = "explosion", self.explosion_cols, boom_peak
            start = first * PATCH_HOP_SECONDS
            end = min(duration, last * PATCH_HOP_SECONDS + PATCH_SECONDS)
            events.extend(self._describe(kind, wave, scores[first:last + 1],
                                         start, end, peak, cols, burst_gap))
        events.sort(key=lambda e: e["start_seconds"])
        return {"audio_available": True, "audio_events": events}

    @staticmethod
    def _stretches(score, min_score):
        """Neighbouring patches above min_score, merged:
        [(first patch, last patch, highest score), ...]. Patches overlap by
        half; up to 2 quieter patches in between (about 1 s, e.g. the pause
        between semi-automatic shots) still count as the same stretch."""
        stretches = []
        for i in np.flatnonzero(score >= min_score):
            if stretches and i - stretches[-1][1] <= 3:
                first, _, peak = stretches[-1]
                stretches[-1] = (first, int(i), max(peak, float(score[i])))
            else:
                stretches.append((int(i), int(i), float(score[i])))
        return stretches

    def _describe(self, kind, wave, part, start, end, peak, cols, burst_gap):
        labels = self.tagger.labels
        strongest = part.max(axis=0)          # each class's highest score
        # The description: the strongest real-weapon class ("Cap gun", a toy,
        # still counts towards the score but isn't used as the description).
        named = [c for c in cols if labels[c] != "Cap gun"]
        sound_label = labels[named[int(np.argmax(strongest[named]))]]
        fireworks = float(strongest[self.look_alike_cols].max())
        base = {
            "event_type": kind,                       # gunfire / explosion
            "sound_label": sound_label,               # e.g. "Machine gun"
            "confidence": round(peak, 2),             # YAMNet's score 0-1
            "fireworks_score": round(fireworks, 2),
            "explosion_score": round(float(strongest[self.explosion_cols].max()), 2),
            # True when the sound is about as much like fireworks/firecrackers
            "could_be_fireworks": fireworks >= 0.8 * peak,
        }
        if kind == "explosion":
            return [dict(base, start_seconds=round(start, 2), end_seconds=round(end, 2))]
        # Gunfire that sounds at least as much like an explosion: flag it.
        base["could_be_explosion"] = base["explosion_score"] >= peak

        # Gunfire: split the bangs into groups and read each group's rhythm.
        bangs, clicks = find_bangs(wave, start, end)
        groups, group = [], []
        for t in bangs:
            if group and t - group[-1] > burst_gap:
                groups.append(group)
                group = []
            group.append(t)
        if group:
            groups.append(group)
        if not groups:                       # the model heard gunfire, but no
            groups = [[]]                    # clear shots: still report it
        base["clicks_not_counted"] = clicks
        # only clicks, no ringing shots: probably handling (or a door / knock)
        base["could_be_handling"] = clicks > 0 and not bangs

        events = []
        for g in groups:
            mode, note, details = fire_mode(g)
            if mode == "automatic" and base["could_be_explosion"]:
                # Continuous rumble (an explosion, heavy clipping) can make
                # evenly spaced fake "bangs": don't claim automatic fire then.
                mode = "unclear"
                note = ("evenly spaced bangs, but it sounds at least as much like an "
                        "explosion or rumble - check by ear")
            if base["could_be_handling"]:
                note = ("no ringing gunshots, only short clicks/knocks - could be "
                        "gun handling (loading, cocking) rather than shots")
            events.append(dict(
                base,
                start_seconds=round(g[0], 2) if g else round(start, 2),
                end_seconds=round(g[-1], 2) if g else round(end, 2),
                shots=len(g),
                shot_times=g[:100],
                fire_mode=mode,
                fire_mode_note=note,
                **details,
            ))
        return events
