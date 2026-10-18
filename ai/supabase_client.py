import os
from datetime import datetime, timezone
from supabase import create_client
from dotenv import load_dotenv

load_dotenv()

def get_client():
    url = os.getenv("SUPABASE_URL")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise RuntimeError("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in ai/.env")
    return create_client(url, key)

def save_detections(media_id, detections):
    client = get_client()
    client.table("media").update({
        "processingstatus": "processing"
    }).eq("mediaid", media_id).execute()

    vehicles = 0
    people = 0

    for item in detections:
        detection = client.table("detection").insert({
            "mediaid": media_id,
            "detectiontype": item["detection_type"],
            "frametimestamp": item["frame_time_seconds"],
            "boundingbox": item["bounding_box"],
            "confidencescore": item["confidence"],
            "modelversion": item["model_version"],
        }).execute()

        detection_id = detection.data[0]["detectionid"]

        if item["detection_type"] == "vehicle":
            vehicles += 1
            client.table("vehicledetail").insert({
                "detectionid": detection_id,
                "vehicletype": item["class_name"],
                "platedetected": False,
            }).execute()
        elif item["detection_type"] == "person":
            people += 1

    summary = f"Detected {vehicles} vehicles and {people} people."
    client.table("media").update({
        "processingstatus": "completed",
        "aidescription": summary,
        "aidescribedat": datetime.now(timezone.utc).isoformat(),
    }).eq("mediaid", media_id).execute()

    return summary