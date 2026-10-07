import json
import sys
from datetime import datetime
from detector import ArgusDetector

def main():
    if len(sys.argv) < 2:
        print("Usage: python main.py path\\to\\video.mp4")
        return

    video_path = sys.argv[1]
    detector = ArgusDetector()
    detections = detector.process_video(video_path)

    output = {
        "video_path": video_path,
        "processed_at": datetime.now().isoformat(),
        "total_detections": len(detections),
        "detections": detections,
    }

    with open("output_detections.json", "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)

    print(f"Saved {len(detections)} detections to output_detections.json")

if __name__ == "__main__":
    main()
    