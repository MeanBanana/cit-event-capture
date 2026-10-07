import cv2
from ultralytics import YOLO

class ArgusDetector:
    def __init__(self):
        self.vehicle_model = YOLO("yolov8n.pt")
        self.vehicle_classes = {2: "car", 3: "motorcycle", 5: "bus", 7: "truck"}

    def process_video(self, video_path, sample_every=10, min_conf=0.45):
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            raise FileNotFoundError(f"Could not open video: {video_path}")

        fps = cap.get(cv2.CAP_PROP_FPS) or 25
        detections = []
        frame_number = 0

        while True:
            ok, frame = cap.read()
            if not ok:
                break
            frame_number += 1
            if frame_number % sample_every != 0:
                continue

            frame_time = round(frame_number / fps, 2)
            results = self.vehicle_model(frame, verbose=False)[0]

            for box in results.boxes:
                class_id = int(box.cls[0])
                confidence = float(box.conf[0])
                if confidence < min_conf:
                    continue

                x1, y1, x2, y2 = [round(float(v), 1) for v in box.xyxy[0]]
                if class_id in self.vehicle_classes:
                    detections.append({
                        "detection_type": "vehicle",
                        "class_name": self.vehicle_classes[class_id],
                        "confidence": round(confidence, 3),
                        "bounding_box": [x1, y1, x2, y2],
                        "frame_number": frame_number,
                        "frame_time_seconds": frame_time,
                        "model_version": "yolov8n",
                    })
                elif class_id == 0:
                    detections.append({
                        "detection_type": "person",
                        "class_name": "person",
                        "confidence": round(confidence, 3),
                        "bounding_box": [x1, y1, x2, y2],
                        "frame_number": frame_number,
                        "frame_time_seconds": frame_time,
                        "model_version": "yolov8n",
                    })

        cap.release()
        return detections