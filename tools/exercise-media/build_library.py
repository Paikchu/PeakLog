#!/usr/bin/env python3
"""Merges the curated PeakLog exercise library with the exercises-dataset.

The curated 135 entries are authoritative: their ids, hand-written Chinese
names, aliases and popularity are preserved verbatim so existing workout
history (which references exercise ids) keeps resolving. Each one gains a
`mediaId` pointing at its animation. Every dataset record that isn't already
covered is appended with a composed Chinese name.

Outputs two files, deliberately split:
  exercise_library.json  — search/list index, loaded eagerly
  exercise_details.json  — instructions + muscle detail, loaded lazily

    ./build_library.py <dataset-dir> <repo-root>
"""

import json
import re
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).parent

# --- Dataset vocabulary → app enums -----------------------------------------

EQUIPMENT_MAP = {
    "barbell": "barbell",
    "ez barbell": "barbell",
    "olympic barbell": "barbell",
    "trap bar": "barbell",
    "dumbbell": "dumbbell",
    "cable": "cable",
    "kettlebell": "kettlebell",
    "leverage machine": "machine",
    "smith machine": "machine",
    "sled machine": "machine",
    "assisted": "machine",
    "skierg machine": "machine",
    "stationary bike": "machine",
    "elliptical machine": "machine",
    "stepmill machine": "machine",
    "upper body ergometer": "machine",
    "body weight": "bodyweight",
    "weighted": "other",
    "band": "other",
    "resistance band": "other",
    "stability ball": "other",
    "bosu ball": "other",
    "medicine ball": "other",
    "roller": "other",
    "wheel roller": "other",
    "rope": "other",
    "hammer": "other",
    "tire": "other",
}

# `body_part` is the coarse grouping; `target` refines the cases where one
# body part spans two app groups (e.g. back holds both lats and spine work).
BODY_PART_MAP = {
    "chest": "chest",
    "back": "back",
    "shoulders": "shoulders",
    "upper arms": "arms",
    "lower arms": "arms",
    "upper legs": "legs",
    "lower legs": "legs",
    "waist": "core",
    # MuscleGroup.fullBody's rawValue is snake_case; emitting "fullBody" here
    # would fail to decode on the Swift side.
    "neck": "full_body",
    "cardio": "full_body",
}

TARGET_OVERRIDE = {
    "spine": "core",
    "serratus anterior": "core",
    "abs": "core",
    "traps": "back",
    "levator scapulae": "back",
}

# Machine-cardio records duplicate what the app already models as a cardio
# activity (distance + duration), so they'd only pollute the strength picker.
CARDIO_MACHINE_EQUIPMENT = {
    "stationary bike",
    "elliptical machine",
    "stepmill machine",
    "upper body ergometer",
    "skierg machine",
}
EXCLUDED_NAMES = {"run", "run (equipment)", "walking on incline treadmill", "push to run"}

BODYWEIGHT_EQUIPMENT = {
    "body weight",
    "assisted",
    "band",
    "resistance band",
    "stability ball",
    "bosu ball",
    "roller",
    "wheel roller",
    "rope",
}

# New entries stay below the curated set's popularity band so the common lifts
# the user actually trains keep surfacing first in the picker.
EQUIPMENT_POPULARITY = {
    "barbell": 34,
    "dumbbell": 34,
    "body weight": 32,
    "cable": 30,
    "leverage machine": 26,
    "smith machine": 24,
    "kettlebell": 22,
    "ez barbell": 22,
    "band": 18,
    "weighted": 18,
}


def normalize(text):
    text = unicodedata.normalize("NFKD", text.lower())
    text = text.replace("в°", "°")  # mojibake in a few source records
    return " ".join(re.sub(r"[^a-z0-9°]+", " ", text).split())


def tokens(text):
    return [t for t in normalize(text).split() if t]


def slugify(text):
    slug = re.sub(r"[^a-z0-9]+", "-", normalize(text)).strip("-")
    return slug or "exercise"


# --- Chinese name composition ------------------------------------------------


class Translator:
    def __init__(self, glossary):
        self.overrides = glossary["name_overrides"]
        self.phrases = glossary["phrases"]
        self.words = glossary["words"]
        self.drop = set(glossary["drop_words"])
        # Longest phrase first so "one arm" wins over "one" + "arm".
        self.phrase_keys = sorted(self.phrases, key=lambda p: -len(p.split()))
        self.untranslated = set()

    def translate(self, name):
        key = normalize(name)
        if key in self.overrides:
            return self.overrides[key], True

        # Version and camera-angle suffixes carry meaning worth keeping, but
        # they must not feed the token pipeline.
        suffix = ""
        version = re.search(r"\bv\.? ?(\d+)", key)
        if version:
            suffix += f"（变式{version.group(1)}）"
            key = re.sub(r"\bv\.? ?\d+", " ", key)
        for pov, label in (("back pov", "背面"), ("side pov", "侧面"), ("front pov", "正面")):
            if pov in key:
                suffix += f"（{label}视角）"
                key = key.replace(pov, " ")

        parts = tokens(key)
        out = []
        i = 0
        matched_any = False
        while i < len(parts):
            hit = None
            for phrase in self.phrase_keys:
                pt = phrase.split()
                if parts[i:i + len(pt)] == pt:
                    hit = (self.phrases[phrase], len(pt))
                    break
            if hit:
                out.append(hit[0])
                i += hit[1]
                matched_any = True
                continue

            word = parts[i]
            if word in self.drop:
                i += 1
                continue
            if word in self.words:
                out.append(self.words[word])
                matched_any = True
            elif re.fullmatch(r"\d+°?", word):
                out.append(word.replace("°", "度"))
            else:
                self.untranslated.add(word)
                out.append(word)
            i += 1

        return ("".join(out) + suffix).strip(), matched_any


# --- Matching curated entries to dataset records -----------------------------

EQUIPMENT_COMPAT = {
    "barbell": {"barbell", "ez barbell", "olympic barbell", "trap bar", "smith machine"},
    "dumbbell": {"dumbbell"},
    "cable": {"cable"},
    "machine": {"leverage machine", "smith machine", "sled machine", "assisted"},
    "bodyweight": {"body weight", "assisted", "weighted"},
    "kettlebell": {"kettlebell"},
    "other": set(EQUIPMENT_MAP),
}

STOP = {"the", "a", "of", "on", "in", "to", "with", "and", "for", "exercise", "male", "female"}


def match_score(curated, record, record_group):
    ct = set(tokens(curated["nameEN"])) - STOP
    rt = set(tokens(record["name"])) - STOP
    if not ct or not rt:
        return 0.0

    overlap = len(ct & rt)
    # Every curated word must appear, otherwise "bench press" happily matches
    # "band bench press" and "barbell row" matches "barbell curl".
    coverage = overlap / len(ct)
    noise = len(rt - ct)
    score = coverage * 100 - noise * 12

    if record["equipment"] in EQUIPMENT_COMPAT.get(curated["equipment"], set()):
        score += 22
    else:
        score -= 30
    if record_group == curated["muscleGroup"]:
        score += 14
    else:
        score -= 25
    return score


def muscle_group_for(record):
    if record["target"] in TARGET_OVERRIDE:
        return TARGET_OVERRIDE[record["target"]]
    return BODY_PART_MAP.get(record["body_part"], "full_body")


def load_type_for(record):
    if record["equipment"] in BODYWEIGHT_EQUIPMENT:
        return "bodyweight"
    return "weighted"


def popularity_for(record):
    base = EQUIPMENT_POPULARITY.get(record["equipment"], 14)
    # Canonical movements have short names; long ones are niche variants.
    extra = max(0, len(tokens(record["name"])) - 3)
    return max(8, base - extra * 2)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    dataset_dir = Path(sys.argv[1])
    repo = Path(sys.argv[2])
    review_only = "--review" in sys.argv

    records = json.loads((dataset_dir / "data" / "exercises.json").read_text())
    library_path = repo / "PeakLog" / "Resources" / "exercise_library.json"
    # The curated 135 live here, not in the generated library: this script
    # overwrites its own output, so reading the seed back would compound the
    # merge on every re-run.
    curated = json.loads((HERE / "curated_seed.json").read_text())["exercises"]
    glossary = json.loads((HERE / "glossary.json").read_text())
    manual_path = HERE / "curated_media_map.json"
    manual = json.loads(manual_path.read_text()) if manual_path.exists() else {}
    manual = {k: v for k, v in manual.items() if not k.startswith("_")}

    curated_ids = {e["id"] for e in curated}
    missing = curated_ids - set(manual)
    stale = set(manual) - curated_ids
    if missing:
        print(f"WARNING: {len(missing)} curated entries not in the media map, "
              f"falling back to fuzzy matching: {sorted(missing)}", file=sys.stderr)
    if stale:
        print(f"WARNING: media map references unknown ids: {sorted(stale)}", file=sys.stderr)

    records = [
        r for r in records
        if r["equipment"] not in CARDIO_MACHINE_EQUIPMENT
        and normalize(r["name"]) not in {normalize(n) for n in EXCLUDED_NAMES}
    ]
    by_id = {r["id"]: r for r in records}
    groups = {r["id"]: muscle_group_for(r) for r in records}

    # --- pair curated entries with their animation ---
    used = set()
    report = []
    for entry in curated:
        forced = manual.get(entry["id"])
        if forced == "":  # explicitly "no good animation"
            report.append((entry, None, 0.0, "none"))
            continue
        if forced:
            report.append((entry, by_id.get(forced), 999.0, "manual"))
            if forced in by_id:
                used.add(forced)
            continue
        best, best_score = None, 0.0
        for record in records:
            score = match_score(entry, record, groups[record["id"]])
            if score > best_score:
                best, best_score = record, score
        if best and best_score >= 78:
            report.append((entry, best, best_score, "auto"))
            used.add(best["id"])
        else:
            report.append((entry, best, best_score, "weak"))

    if review_only:
        for entry, record, score, kind in sorted(report, key=lambda r: r[2]):
            name = record["name"] if record else "—"
            print(f'{kind:6s} {score:6.1f}  {entry["id"]:38s} {entry["nameEN"]:32s} -> {name}')
        strong = sum(1 for r in report if r[3] in ("auto", "manual"))
        print(f"\nmatched {strong}/{len(curated)}")
        return 0

    translator = Translator(glossary)

    # --- build the index ---
    index = []
    details = {}
    seen_ids = {e["id"] for e in curated}
    seen_names = set()

    for entry, record, score, kind in report:
        out = dict(entry)
        if record and kind in ("auto", "manual"):
            out["mediaId"] = record["id"]
            details[entry["id"]] = detail_for(record)
        index.append(out)
        seen_names.add(normalize(entry["nameEN"]))
        seen_names.add(normalize(entry["nameZH"]))

    zh_seen = {e["nameZH"] for e in curated}
    for record in records:
        if record["id"] in used:
            continue
        if normalize(record["name"]) in seen_names:
            continue

        slug = slugify(record["name"])
        if slug in seen_ids:
            slug = f"{slug}-{record['id']}"
        seen_ids.add(slug)

        name_zh, ok = translator.translate(record["name"])
        if not ok or not name_zh:
            name_zh = record["name"]
        # The source has genuine near-duplicates (two "ez barbell spider curl"
        # records) and distinct English names that collapse to one Chinese name
        # ("straight leg"/"stiff leg" deadlift). Number them rather than leaking
        # the dataset id into the UI.
        if name_zh in zh_seen:
            base, n = name_zh, 2
            while f"{base}（变式{n}）" in zh_seen:
                n += 1
            name_zh = f"{base}（变式{n}）"
        zh_seen.add(name_zh)

        index.append({
            "id": slug,
            "nameEN": record["name"],
            "nameZH": name_zh,
            "aliases": [],
            "muscleGroup": groups[record["id"]],
            "equipment": EQUIPMENT_MAP.get(record["equipment"], "other"),
            "loadType": load_type_for(record),
            "popularity": popularity_for(record),
            "mediaId": record["id"],
        })
        details[slug] = detail_for(record)

    library_path.write_text(
        json.dumps({"version": 2, "exercises": index}, ensure_ascii=False, indent=1) + "\n"
    )
    (repo / "PeakLog" / "Resources" / "exercise_details.json").write_text(
        json.dumps({"version": 1, "attribution": records[0]["attribution"], "details": details},
                   ensure_ascii=False, indent=1) + "\n"
    )

    with_media = sum(1 for e in index if e.get("mediaId"))
    print(f"exercises: {len(index)}  with animation: {with_media}  details: {len(details)}")
    print(f"curated matched: {sum(1 for r in report if r[3] in ('auto','manual'))}/{len(curated)}")
    if translator.untranslated:
        print(f"untranslated tokens ({len(translator.untranslated)}): "
              f"{' '.join(sorted(translator.untranslated)[:40])}")
    return 0


def detail_for(record):
    return {
        "mediaId": record["id"],
        "target": record["target"],
        "secondaryMuscles": record.get("secondary_muscles", []),
        "stepsEN": record.get("instruction_steps", {}).get("en", []),
        "stepsZH": record.get("instruction_steps", {}).get("zh", []),
    }


if __name__ == "__main__":
    sys.exit(main())
