# Argus AI pipeline

Finds vehicles, people and **weapons** in a video (or a single photo),
follows each one across frames, and identifies each vehicle's **make**
(brand), **colour** and **number plate**. It also **listens** to the video for
**gunfire and explosions**, and tells from the rhythm of the shots whether the
fire sounds **automatic** or **semi-automatic**.
For **people** it counts how many are visible at once, suggests clothing
colours, and saves a picture of each person whose face is clear enough for an
investigator to look at.

## Run it

```bash
pip install -r requirements.txt        # first time (and after requirements change)
python main.py path/to/video.mp4
python main.py path/to/photo.jpg       # photos work too
python main.py clip1.mp4 clip2.mp4 photo.jpg   # up to 5 files = ONE submission
```

**Submissions.** Every run is one submission of 1–5 videos/photos that belong
together (e.g. one witness's clips of the same robbery), numbered
automatically: `crops/submission 1`, `crops/submission 2`, ... Each has a
`results.json` (everything found, per file, plus totals) and one picture
folder per file, e.g. `crops/submission 2/1_clip1/`, `crops/submission 2/2_clip2/`.
`output_detections.json` is a copy of the latest submission's results.
Track numbers are per file: Person #7 in two different clips are not
necessarily the same person.

**Accepted files.** Photos: JPEG, PNG, WebP, BMP, TIFF, GIF (first frame) and
iPhone HEIC/HEIF (via `pillow-heif`). Phone photos are turned the right way up
automatically. Videos: MP4, MOV, AVI, MKV, M4V, 3GP, WebM.

**Photos vs videos.** A photo is one view, so there is no tracking and no
voting across frames: answers are less certain than from a video. A plate is
reported from one clear reading (a video needs 2 frames to agree), and a car
touching the photo's edge is still judged at half weight.

Output (all pictures are PNG: lossless, so no compression smudging on
plates and faces):

In each submission's per-file folder (`crops/submission N/<n>_<file>/`):

* `vehicle_<id>.png` — each vehicle's clearest picture
* `plate_<id>.png` — each vehicle's clearest plate picture (enlarged)
* `person_<id>.png` + `face_<id>.png` — whole person + face
  close-up, **only** for people whose face was clear enough (see below)
* `weapon_<id>.png` — each weapon's clearest picture (enlarged)
* `people_peak.png` — the frame with the most people, boxed, to check
  the count by eye

plus `crops/submission N/results.json` (one entry per tracked
vehicle/person/weapon and the sounds heard, for every file).
* a summary in the terminal, e.g.
  `Vehicle #3   car   Toyota (90%)   white (80%)   seen in 15 frames`

The percentages are the answer's share of all the evidence from that
vehicle's frames (better views count more). Low numbers (under ~60%) mean the
views disagreed: check `make_top3` / `colour_top3` in the JSON and the crop.
Below 40% the answer is not reported at all (`make: null`, shown as
"unsure: Opel?") — an honest "unknown" is safer than a wrong make sending
investigators after the wrong car. The guesses stay in `make_top3`.

**Plates** are only reported when read clearly in at least 2 frames with at
least 40% agreement (`plate: null` otherwise, guesses kept in `plate_top3`).
A wrong plate could send investigators after an innocent driver, so the
filters are strict on purpose.

**People pictures and POPIA.** Faces are only *found* (to pick a good
frame), never identified: no face recognition, no comparing faces. Every
person is only a *possible* suspect until an investigator on the case
decides. Clothing colours are AI suggestions to speed up their description.
"Face clear enough" = at least 36 px tall and sharp, which is roughly a person
within ~5 m on normal 1080p phone video. People further away still get counted
and clothing colours, just no picture.

**Weapons** (`weapons.py`): four kinds — `handgun`, `long_gun` (rifles incl.
AK-style, shotguns), `knife`, `machete` — each linked to the person holding it
(`held_by_person` = that person's track ID). A camera can't tell automatic from
semi-automatic; that comes from the sound. Until we train our own model it uses
**YOLOE**, which finds objects from text ("handgun", "rifle", ...) with no
training: a stopgap, so expect misses and some false alarms (phones, tools).
Small or far-away weapons are often missed, so "no weapon" doesn't mean there
was none. **CIT guards are armed too**: a weapon next to a person says nothing
about who the robber is.

**Sound** (`audio.py`, videos only): YAMNet (Google's free sound-recognition
model) finds stretches that sound like gunfire or an explosion. In gunfire we
find each bang and measure the gaps: 4+ bangs 0.05–0.14 s apart and evenly
spaced = **automatic** (with rounds per minute); gaps of 0.15 s+ =
**semi-automatic or single shots** (an automatic fired one shot at a time
sounds the same); otherwise **unclear**. Timing is used because it survives
phone microphones and WhatsApp compression. Two filters, tuned on real
shooting clips:
* **echoes** — a bang 4+ dB quieter than a bang just before it is an echo
  (an indoor range's back wall echoed every shot 0.15 s later, 5–12 dB quieter)
* **gun handling** — a gunshot rings on (only ~17–20 dB quieter 50–250 ms
  later); loading/cocking clicks die away (35–50 dB). Clicks aren't counted
  as shots; an event with only clicks gets `could_be_handling: true`

Each event also has `could_be_fireworks` / `could_be_explosion` flags, and
"automatic" is never claimed when it sounds as much like an explosion.
Results so far: real AK and AR-15/pistol range clips — every shot found as a
single shot, echoes and handling clicks correctly ignored; music clips — no
false alarms; synthetic automatic bursts — found (heavily clipped audio comes
out "unclear", never a wrong answer). **Not yet tested on real automatic
fire**: try a few full-auto range videos before relying on "automatic".

**First run with weapons:** YOLOE turns the text prompts into numbers once,
which needs the `clip` package; Ultralytics installs it by itself, but that
needs **Git** installed. The result is saved as
`weapon_models/yoloe_prompts.npz` — commit that file and nobody else needs
this step.

**Footage resolution matters most for plates (and faces).** A plate needs roughly 80+
pixels of width to be readable. Videos shared via WhatsApp etc. are shrunk
(our test clips are 478x850 and 440x640; plates there are ~40 px wide and
unreadable even by a person), so upload the ORIGINAL file from the phone.

**Vehicle sizes.** Each detail needs a different amount of detail in the
picture: **colour** is judged from ~30 px (blur doesn't change a colour much),
**plates** from 60 px, **make** only from 120 px and only reported at 60%+
agreement (a confident wrong brand is worse than "unknown"; e.g. on a 440x640
TikTok clip it called a Hyundai a "SEAT 75%" and a Toyota Quantum a
"Peugeot"). Smaller vehicles print `make: too far` (`make_views: 0` in the
JSON).

**Known limit:** the make model is much less reliable on small rear views
(e.g. a dashcam following at a distance) than on close front/side views, and
on SA-specific vehicles (Quantum taxis, UD trucks). Expect "unsure" or "too
far" makes on that kind of footage; colours hold up better.

**Speed:** it checks every frame with a bigger model, plus the weapon model on
every 2nd frame, so on a laptop CPU expect roughly 5-9 minutes per minute of
video (the sound analysis takes only seconds). To skip a step while testing,
`process_video(..., weapon_every=4)` checks weapons less often. For a quicker run, change
`sample_every=1` to `2` in `main.py`'s `process_video(...)` call, or use
`ArgusDetector("yolo26n.pt")`.

## How it works

| Step | What | Where |
|---|---|---|
| Find | YOLO26s finds vehicles and people in every frame | `detector.py` |
| Track | TrackTrack (with camera-motion compensation for shaky footage) gives each object an ID that stays the same across frames, even if briefly hidden, so one car = one result | `detector.py`, `argus_tracker.yaml` |
| Identify | Every 3rd frame, each clearly visible vehicle is cropped and the models give a probability for every make and colour. Make is judged on the picture and its mirror image; dark pictures get a contrast boost first | `vehicle_classifier.py` |
| Weigh | Bigger, sharper, surer views count more. Tiny (< 60 px), very blurry, or cut-off (touching the picture edge) views don't count | `detector.py` (`view_quality`) |
| Plates | On the same good views, FastALPR finds the plate and reads each character with a confidence. Only clear readings count (every character ≥ 40% sure, average ≥ 75%); readings matching South African formats count more, and look-alike mix-ups (O/0, I/1, B/8, S/5, Z/2, G/6) are fixed when that makes a valid SA plate. Readings one character apart are merged | `plate_reader.py` |
| Weapons | YOLOE (or our trained model, once `weapon_models/best.pt` exists) finds handguns, long guns, knives and machetes on every 2nd frame, with its own tracker; each weapon's kind is voted over frames and it's linked to the person whose (slightly widened) box it's in most often | `weapons.py` |
| Sound | YAMNet scores each 0.48 s of sound for gunfire / explosion; bangs are found where loudness (above 500 Hz) jumps 10 dB+; their spacing gives automatic / semi-automatic / unclear | `audio.py` |
| People | Most people visible at the same time is counted (safer than counting IDs: someone hidden for a while can come back with a new ID). For each person: upper/lower clothing colours are voted over frames, and a face finder (YuNet) looks for their face; the clearest frame with a face at least 36 px tall and sharp is saved | `people.py`, `colours.py` |
| Decide | The make / colour with the highest total wins ("soft voting"); objects seen in fewer than 3 frames are dropped | `detector.py` (`_summarise`) |

If the make/colour models can't load (e.g. `MNN` not installed), it still
runs: colour falls back to a k-means method and make is left empty.

## Training the weapon model

`training/train_weapon_model_v3.ipynb` trains our own detector for `handgun`,
`long_gun`, `knife` and `machete` on Google Colab's free GPU. No accounts are
needed apart from Google.

1. Go to <https://colab.research.google.com> → **File → Upload notebook** →
   choose `ai/training/train_weapon_model_v3.ipynb`.
2. **Runtime → Change runtime type → T4 GPU → Save**.
3. **Runtime → Run all**, allow Google Drive access, and wait (about 3–4 hours).
   If Colab disconnects, **Run all** again: it continues where it stopped
   (progress is saved in Drive under `argus_weapons/`).
4. `best.pt` downloads at the end. Put it at **`ai/weapon_models/best.pt`** —
   `weapons.py` then uses it instead of YOLOE automatically.

What it does: downloads ~9,700 labelled weapon images (Hugging Face
`Subh775/WeaponDetection`, CC BY 4.0) plus Open Images photos of handguns,
rifles, shotguns, knives, daggers and swords, and ~2,000 photos of look-alikes
(phones, drills, umbrellas, torches…) with no weapons, so it learns those are
*not* weapons. Pictures labelled only "gun"/"weapon" (kind unknown) are left
out. It fine-tunes YOLO26s, then prints precision/recall/mAP50 per class on
test pictures it never trained on (mAP50 0.7+ is good).

Limits: no public dataset has machetes, so `machete` learns from swords;
the training photos are mostly close and clear, unlike far-away CCTV/phone
footage. Biggest next improvement: label a few hundred frames from real SA
robbery footage and machete/panga pictures (Roboflow, free), add them to the
training data, and train again.

## Files

| File | Purpose |
|---|---|
| `main.py` | Runs the detector on a video or photo and saves/prints the results |
| `detector.py` | Detection, tracking, weighting, voting, crops |
| `argus_tracker.yaml` | Tracker settings (TrackTrack, tuned to keep IDs through short occlusions) |
| `vehicle_classifier.py` | Runs the make and colour models on a vehicle picture |
| `plate_reader.py` | Finds and reads number plates; SA plate formats; combines readings |
| `people.py` | Face finding (pictures for investigators), clothing colours |
| `weapons.py` | Weapon finding (YOLOE or our trained model) + who is holding it |
| `audio.py` | Gunfire / explosion detection in the sound + automatic vs semi-automatic |
| `training/` | Colab notebook that trains the weapon model |
| `weapon_models/` | Our trained weapon model (`best.pt`, later) + YOLOE's saved prompts |
| `audio_models/` | YAMNet sound model (converted to ONNX) + class names + licence |
| `colours.py` | Shared "main colour of a patch" helper (k-means + colour names) |
| `people_models/` | YuNet face-finder model + its licence |
| `vehicle_models/` | The two pretrained models + their label lists and licence |

## Credits

Make and colour models: **Spectrico** car brand and car colour recognition
(MobileNet v3, MIT licence), from
<https://github.com/TheDeveloperMask/vehicle-recognition-api-yolov4-python>.
Licence text in `vehicle_models/LICENSE`. The make model knows several hundred
makes, including the common South African brands (Toyota, VW, Ford, Nissan,
Hyundai, Isuzu, Mercedes-Benz, BMW, Kia, Suzuki, Renault, Mahindra, Chevrolet,
Audi, Honda, Chery, Mazda, Opel, Datsun, GWM); Haval is not included.
Colours: black, white, grey, silver, blue, red, green, brown, beige, golden,
bordeaux, yellow, violet, orange.

Sound recognition: **YAMNet** (Apache 2.0, Google),
<https://github.com/tensorflow/models/tree/master/research/audioset/yamnet>.
Converted to ONNX for this project (no TensorFlow needed); our sound
preparation matches the original to within 0.0001. Licence in `audio_models/LICENSE`.

Weapons (stopgap): **YOLOE** (Ultralytics, AGPL-3.0), open-vocabulary detection.
Weapon training data: **Subh775/WeaponDetection** (CC BY 4.0, Hugging Face, from a
Roboflow Universe dataset) and **Open Images V7** (Google; annotations CC BY 4.0).

Face finding: **YuNet** (MIT, Shiqi Yu), from OpenCV's model zoo
<https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet>.
Licence in `people_models/LICENSE`.

Number plates: **FastALPR** (MIT) — YOLOv9 plate detector + fast-plate-ocr
"cct-s-v2-global-model" (trained on 65+ countries; South Africa isn't one of
them, but SA plates are read when clear). <https://github.com/ankandrew/fast-alpr>

Vehicle/person detection and tracking: Ultralytics YOLO26 (AGPL-3.0) with
TrackTrack ("Focusing on Tracks for Online Multi-Object
Tracking", CVPR 2025).

## Still to do

* Measure accuracy: label 30-50 SA clips/crops (real make + colour) and
  compare with the pipeline's answers, before and after each change

* Check plate accuracy on full-resolution SA footage; if SA plates are misread
  often, fine-tune fast-plate-ocr on labelled SA plate crops
* Run `training/train_weapon_model_v3.ipynb` on Colab and add the resulting
  `weapon_models/best.pt` (see "Training the weapon model")
* Test the sound analysis on real gunfire recordings
* Save results to Supabase (`detection`, `vehicledetail`) with the service key
* Real capture time from the video's metadata
