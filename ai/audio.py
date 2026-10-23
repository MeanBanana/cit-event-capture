"""
Listens to a video's audio for gunfire and explosions, and tries to tell
automatic from semi-automatic fire based on the timing between shots.

How it goes:
  1. Pull the audio out with ffmpeg (the one bundled in imageio-ffmpeg, so
     there's nothing extra to install).
  2. Run YAMNet over it. It's Google's general sound classifier (521
     classes) and gives us scores for things like "Gunshot, gunfire",
     "Machine gun", "Explosion" and "Fireworks" every half second.
  3. Inside anything that sounds like gunfire, find the individual bangs and
     look at the gaps. Automatic fire is fast (~0.05-0.14s apart) and very
     regular because the gun sets the pace. Semi-auto is one trigger pull per
     shot, so slower and messier. Anything in between is "unclear".

We go by timing rather than the sound itself because phone mics clip on loud
bangs and WhatsApp mangles the audio, but the timing survives both.

Known weak spots (which is why this is only ever a lead):
  - echoes look like extra bangs. We drop bangs that are much quieter than
    the one just before, and anything messy ends up "unclear".
  - loading/cocking clicks can fool YAMNet. Real shots ring on, clicks die
    almost instantly, so we filter on that (could_be_handling).
  - fireworks, backfires and slammed doors. We report the fireworks score
    alongside so someone can check.
  - an automatic fired one shot at a time just looks like semi-auto.

YAMNet is Apache 2.0, (c) Google:
https://github.com/tensorflow/models/tree/master/research/audioset/yamnet
We converted it to ONNX so we don't need TensorFlow. The preprocessing below
is a straight port of YAMNet's and matches the original to within 0.0001.
"""

import subprocess
from pathlib import Path

import numpy as np

MODELS = Path(__file__).parent / "audio_models"
YAMNET_MODEL = MODELS / "yamnet.onnx"
YAMNET_LABELS = MODELS / "yamnet_class_map.csv"

SAMPLE_RATE = 16000

# names as they appear in yamnet_class_map.csv
GUN_CLASSES = ["Gunshot, gunfire", "Machine gun", "Fusillade", "Artillery fire", "Cap gun"]
EXPLOSION_CLASSES = ["Explosion", "Boom"]
LOOK_ALIKE_CLASSES = ["Fireworks", "Firecracker"]

# Gaps between bangs, in seconds
MIN_GAP = 0.05          # closer than this is the same bang (or its echo)
AUTO_MAX_GAP = 0.14     # ~450 rounds/min and up
SEMI_MIN_GAP = 0.15
AUTO_MAX_UNEVENNESS = 0.25   # auto fire gaps vary by less than ~25%


# --- pulling the audio out

def load_audio(path, sample_rate=SAMPLE_RATE):
    """Mono float32 audio at `sample_rate`, or None if there's no sound track."""
    import imageio_ffmpeg
    command = [imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-v", "error",
               "-i", str(path), "-vn", "-ac", "1", "-ar", str(sample_rate),
               "-f", "f32le", "-"]
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0 or not result.stdout:
        return None
    return np.frombuffer(result.stdout, dtype=np.float32).copy()


# --- YAMNet

# Copied from YAMNet's features.py: 25ms windows every 10ms, 64 mel bands
# from 125-7500Hz, log, then 0.96s patches every 0.48s. Don't tweak these,
# the model was trained on exactly this.
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
    """Pad with silence to a whole number of patches, same as YAMNet does."""
    min_samples = int((PATCH_SECONDS + 0.025 - 0.010) * SAMPLE_RATE)
    n = len(wave)
    padding = max(0, min_samples - n)
    n = max(n, min_samples)
    hop = int(PATCH_HOP_SECONDS * SAMPLE_RATE)
    extra = n - min_samples
    padding += hop * int(np.ceil(extra / hop)) - extra
    return np.pad(wave, (0, padding))


def log_mel_patches(wave):
    """Turn a 16kHz mono wave into YAMNet input, shape (patches, 96, 64)."""
    wave = _pad(np.asarray(wave, np.float32))
    frames = 1 + (len(wave) - _WIN) // _HOP
    index = np.arange(_WIN)[None, :] + _HOP * np.arange(frames)[:, None]
    magnitude = np.abs(np.fft.rfft(wave[index] * _WINDOW, n=_NFFT, axis=1)).astype(np.float32)
    log_mel = np.log(magnitude @ _MEL + 0.001)
    patches = 1 + (len(log_mel) - PATCH_FRAMES) // PATCH_HOP_FRAMES
    index = np.arange(PATCH_FRAMES)[None, :] + PATCH_HOP_FRAMES * np.arange(patches)[:, None]
    return log_mel[index]


class SoundTagger:
    """Thin wrapper around the YAMNet ONNX model."""

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
        """Scores per patch, shape (patches, 521). Patch i starts at i*0.48s."""
        patches = log_mel_patches(wave)
        out = [self.session.run(None, {self.input_name: patches[i:i + batch]})[0]
               for i in range(0, len(patches), batch)]
        return np.concatenate(out) if out else np.zeros((0, len(self.labels)), np.float32)

    def columns(self, names):
        return [self.index[n] for n in names]


# --- finding individual shots and reading the rhythm

def find_bangs(wave, start, end, frame_ms=2, rise_db=4.0, window_db=20.0,
               look_back=0.03, echo_db=4.0, echo_window=0.5, max_tail_drop=28.0):
    """Find the actual gunshots between `start` and `end`.

    Returns (shot times, number of clicks we threw out). Three passes:

    1. Candidate bangs: loudness (high-passed at 500Hz to get rid of wind and
       engine noise) jumps `rise_db` above the recent minimum and isn't too
       far below the loudest bang in the stretch.
    2. Echoes: anything `echo_db` quieter than a bang just before it. In our
       test clips echoes were always 5-12dB down, while shots in a burst stay
       about equally loud.
    3. Clicks: a gunshot keeps ringing, 50-250ms later it's only ~17-20dB
       down. Clicks and knocks are 35-50dB down by then. Anything that drops
       more than `max_tail_drop` gets thrown out.

    The dB numbers came from measuring real rifle and pistol recordings.
    """
    from scipy.signal import butter, sosfilt
    total = len(wave) / SAMPLE_RATE
    a = int(max(0, start) * SAMPLE_RATE)
    b = int(min(total, end + 0.3) * SAMPLE_RATE)       # a bit extra to hear the ring-out
    piece = wave[a:b]
    step = int(SAMPLE_RATE * frame_ms / 1000)
    if len(piece) < step * 10:
        return [], 0
    piece = sosfilt(butter(4, 500, "highpass", fs=SAMPLE_RATE, output="sos"), piece)
    frames = len(piece) // step
    rms = np.sqrt(np.mean(piece[:frames * step].reshape(frames, step) ** 2, axis=1))
    loud = 20 * np.log10(rms + 1e-7)
    last = min(frames, int((end - start) * 1000 / frame_ms) + 1)   # don't look for bangs past `end`

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
                bangs[-1] = i            # same bang, keep its loudest frame
            continue
        bangs.append(i)

    def peak(i):
        return loud[i:i + 5].max()

    # echoes
    window = int(echo_window * 1000 / frame_ms)
    kept = []
    for i in bangs:
        recent = [peak(j) for j in kept if i - j <= window]
        if recent and peak(i) <= max(recent) - echo_db:
            continue
        kept.append(i)

    # clicks
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
    """Longest streak of gaps that are in the automatic-fire range."""
    best, run = [], []
    for gap in gaps:
        if MIN_GAP <= gap <= AUTO_MAX_GAP:
            run.append(gap)
            best = run if len(run) > len(best) else best
        else:
            run = []
    return list(best)


def fire_mode(shot_times):
    """Work out the fire mode from a group of shot times.

    Returns (mode, note, details). We want at least 4 evenly spaced bangs
    before calling it automatic, because one shot plus two echoes can look
    like three.
    """
    n = len(shot_times)
    if n == 0:
        return "unclear", "no clear individual bangs found", {}
    if n == 1:
        return "single_shot", "one bang", {}
    gaps = np.diff(shot_times)
    details = {"median_gap_seconds": round(float(np.median(gaps)), 3)}

    run = _regular_run(gaps)
    if len(run) >= 3:                      # 3 gaps = 4 bangs
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


# --- putting it together

class AudioAnalyser:
    """Finds gunfire/explosion events in a video's audio."""

    version = "yamnet-onnx"

    def __init__(self):
        self.tagger = SoundTagger()
        self.gun_cols = self.tagger.columns(GUN_CLASSES)
        self.explosion_cols = self.tagger.columns(EXPLOSION_CLASSES)
        self.look_alike_cols = self.tagger.columns(LOOK_ALIKE_CLASSES)

    def analyse(self, video_path, min_score=0.25, burst_gap=1.0):
        """Analyse one video's audio.

        min_score is how confident YAMNet has to be before we treat a stretch
        as gunfire/explosion. Lower finds more but cries wolf more.
        burst_gap splits shots into separate groups when they're further
        apart than this.
        """
        wave = load_audio(video_path)
        if wave is None or len(wave) < SAMPLE_RATE * 0.2:
            return {"audio_available": False, "audio_events": []}
        scores = self.tagger.scores(wave)
        duration = len(wave) / SAMPLE_RATE

        gun = scores[:, self.gun_cols].max(axis=1)
        boom = scores[:, self.explosion_cols].max(axis=1)

        # YAMNet tends to score gunshots high for "explosion" as well, so we
        # look at each stretch as a whole and call it gunfire unless it's
        # clearly more explosion-y than gun-y.
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
        """Merge neighbouring patches above min_score into stretches of
        (first, last, peak). We allow a gap of a couple of patches (~1s) so
        the pauses between semi-auto shots don't split them up."""
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
        strongest = part.max(axis=0)
        # "Cap gun" (a toy) still adds to the score but we don't want it
        # showing up as the label
        named = [c for c in cols if labels[c] != "Cap gun"]
        sound_label = labels[named[int(np.argmax(strongest[named]))]]
        fireworks = float(strongest[self.look_alike_cols].max())
        base = {
            "event_type": kind,
            "sound_label": sound_label,
            "confidence": round(peak, 2),
            "fireworks_score": round(fireworks, 2),
            "explosion_score": round(float(strongest[self.explosion_cols].max()), 2),
            "could_be_fireworks": fireworks >= 0.8 * peak,
        }
        if kind == "explosion":
            return [dict(base, start_seconds=round(start, 2), end_seconds=round(end, 2))]
        base["could_be_explosion"] = base["explosion_score"] >= peak

        bangs, clicks = find_bangs(wave, start, end)
        groups, group = [], []
        for t in bangs:
            if group and t - group[-1] > burst_gap:
                groups.append(group)
                group = []
            group.append(t)
        if group:
            groups.append(group)
        if not groups:                       # YAMNet heard gunfire but we couldn't
            groups = [[]]                    # pick out shots, report it anyway
        base["clicks_not_counted"] = clicks
        # clicks but nothing that rang on, so probably handling or a door
        base["could_be_handling"] = clicks > 0 and not bangs

        events = []
        for g in groups:
            mode, note, details = fire_mode(g)
            if mode == "automatic" and base["could_be_explosion"]:
                # A continuous rumble can produce evenly spaced fake bangs, so
                # don't claim automatic fire if it might be an explosion
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
