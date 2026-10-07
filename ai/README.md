# Argus AI pipeline

Finds vehicles and people in a video (or a single photo), follows each one
across frames, and
identifies each vehicle's **make** (brand), **colour** and **number plate**.
For **people** it counts how many are visible at once, suggests clothing
colours, and saves a picture of each person whose face is clear enough for an
investigator to look at.

## Run it

```bash
pip install -r requirements.txt        # first time (and after requirements change)
python main.py path/to/video.mp4
python main.py path/to/photo.jpg       # photos work too
```

**Accepted files.** Photos: JPEG, PNG, WebP, BMP, TIFF, GIF (first frame) and
iPhone HEIC/HEIF (via `pillow-heif`). Phone photos are turned the right way up
automatically. Videos: MP4, MOV, AVI, MKV, M4V, 3GP, WebM.

**Photos vs videos.** A photo is one view, so there is no tracking and no
voting across frames: answers are less certain than from a video. A plate is
reported from one clear reading (a video needs 2 frames to agree), and a car
touching the photo's edge is still judged at half weight.

Output (all pictures are PNG: lossless, so no compression smudging on
plates and faces):

* `output_detections.json` — one entry per tracked vehicle/person
* `crops/vehicle_<id>.png` — each vehicle's clearest picture
* `crops/plate_<id>.png` — each vehicle's clearest plate picture (enlarged)
* `crops/person_<id>.png` + `crops/face_<id>.png` — whole person + face
  close-up, **only** for people whose face was clear enough (see below)
* `crops/people_peak.png` — the frame with the most people, boxed, to check
  the count by eye
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

**Footage resolution matters most for plates (and faces).** A plate needs roughly 80+
pixels of width to be readable. Videos shared via WhatsApp etc. are shrunk
(our test clips are 478x850 and 440x640; plates there are ~40 px wide and
unreadable even by a person), so upload the ORIGINAL file from the phone.

**Known limit:** the make model is much less reliable on small rear views
(e.g. a dashcam following at a distance) than on close front/side views.
Expect more "unsure" makes on that kind of footage; colours hold up better.

**Speed:** it now checks every frame with a bigger model, so on a laptop CPU
expect roughly 3-6 minutes per minute of video. For a quicker run, change
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
| People | Most people visible at the same time is counted (safer than counting IDs: someone hidden for a while can come back with a new ID). For each person: upper/lower clothing colours are voted over frames, and a face finder (YuNet) looks for their face; the clearest frame with a face at least 36 px tall and sharp is saved | `people.py`, `colours.py` |
| Decide | The make / colour with the highest total wins ("soft voting"); objects seen in fewer than 3 frames are dropped | `detector.py` (`_summarise`) |

If the make/colour models can't load (e.g. `MNN` not installed), it still
runs: colour falls back to a k-means method and make is left empty.

## Files

| File | Purpose |
|---|---|
| `main.py` | Runs the detector on a video or photo and saves/prints the results |
| `detector.py` | Detection, tracking, weighting, voting, crops |
| `argus_tracker.yaml` | Tracker settings (TrackTrack, tuned to keep IDs through short occlusions) |
| `vehicle_classifier.py` | Runs the make and colour models on a vehicle picture |
| `plate_reader.py` | Finds and reads number plates; SA plate formats; combines readings |
| `people.py` | Face finding (pictures for investigators), clothing colours |
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
* Weapons (needs a weapon detection model)
* Save results to Supabase (`detection`, `vehicledetail`) with the service key
* Real capture time from the video's metadata
