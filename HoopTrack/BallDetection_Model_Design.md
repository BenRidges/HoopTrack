# HoopTrack — Ball Detection Model Design
## Seamless Integration Specification

> This document defines everything required to train, evaluate, and integrate a ball detection model into HoopTrack. It is a companion to `Phase2_Implementation_Plan.md` and focuses exclusively on Step 1 (Ball Detection Model) and its contract with the rest of the CV pipeline.

---

## 1. Integration Overview

The ball detector sits at the entry point of the CV pipeline. Every frame that flows through `CameraService.framePublisher` passes through `BallDetector` first. Its single responsibility is to answer: **"Is there a basketball in this frame, and if so, where?"**

```
CameraService.framePublisher (CMSampleBuffer, 60fps)
    └── BallDetector.detect(buffer:) → CGRect? + confidence
            └── CVPipeline (state machine)
                    └── LiveSessionViewModel.logShot(...)
```

Everything downstream — court calibration, state machine transitions, zone classification, shot logging — depends on the detector producing a reliable, low-latency bounding box. Getting the model contract right is the highest-leverage decision in Phase 2.

---

## 2. Model Contract

This is the interface `BallDetector.swift` will expose to `CVPipeline`. It must not change after the pipeline is built.

### Input

| Property | Value |
|----------|-------|
| Source | `CMSampleBuffer` from `AVCaptureVideoDataOutput` |
| Camera preset | `hd1280x720` (1280×720px) |
| Pixel format | `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (YUV 4:2:0) |
| Orientation | Portrait-locked (90° rotation applied in `CameraService`) |
| Frame rate | 60fps target |
| Model input size | **416×416px** (rescale from 720p at inference time) |

The `BallDetector` is responsible for resizing the pixel buffer to 416×416 before feeding it to the model. It should NOT require the caller to pre-process the buffer.

### Output

```swift
struct BallDetection {
    /// Bounding box in normalised image coordinates (origin top-left, 0–1 range).
    /// Maps directly to Vision framework coordinate space.
    let boundingBox: CGRect

    /// Model confidence score (0–1). Pipeline ignores detections below threshold.
    let confidence: Float

    /// Timestamp of the source frame, used for trajectory interpolation.
    let frameTimestamp: CMTime
}
```

`BallDetector.detect(buffer:)` returns `BallDetection?` — `nil` when no ball is found above the confidence threshold.

### Confidence Threshold

The default threshold is **0.45**. This is deliberately lower than typical object detectors because:
- Missing a ball frame (false negative) causes the pipeline to drop back to IDLE, breaking tracking
- A false positive (wrong bounding box) is recoverable — the trajectory validator will reject it

The threshold is exposed as a tunable constant in `Constants.swift`:

```swift
enum Camera {
    static let ballDetectionConfidenceThreshold: Float = 0.45
}
```

---

## 3. Model Architecture

### Recommended Approach: YOLOv8n (Nano)

YOLOv8 nano is the right balance of speed and accuracy for this use case.

| Property | Target |
|----------|--------|
| Architecture | YOLOv8n (nano) |
| Input resolution | 416×416 |
| Classes | 1 (basketball only) |
| Inference target | < 20ms on A15 Bionic (iPhone 13+) |
| Format | Core ML `.mlpackage` |

**Why YOLOv8n over alternatives:**
- YOLOv5n/v8n consistently hit < 20ms on A15 at 416×416 in Core ML benchmarks
- Single-class models are faster than general sports ball detectors (fewer NMS candidates)
- `coremltools` has mature YOLOv8 → Core ML export support
- MobileNet SSD is also viable but YOLOv8n has better small-object recall (basketball at 3-point range appears small in frame)

### Alternative: MobileNetV3 + SSD

If YOLOv8 proves too slow on older devices (A14 and below):
- MobileNetV3-Small + SSD Head
- Quantise to INT8 via `coremltools` for < 10ms on A14
- Accuracy tradeoff: ~3–5% lower mAP on small balls in complex backgrounds

The `BallDetector.swift` wrapper is architecture-agnostic — swapping models requires only replacing the `.mlpackage` file.

---

## 4. Training Data Requirements

### Volume

| Split | Minimum | Recommended |
|-------|---------|-------------|
| Train | 3,000 images | 8,000+ images |
| Validation | 500 images | 1,500 images |
| Test | 300 images | 500 images |

### Required Scene Variety

The model will be used in real gyms. Training data must cover:

**Lighting conditions**
- Bright fluorescent gym lighting (primary use case)
- Dim or uneven gym lighting
- Mixed natural + artificial light near windows
- Overhead court lighting with shadows on floor

**Ball positions / states**
- Ball in hand (pre-shot) — needs to be detected for trajectory start
- Ball in flight (arc) — most critical, must track across full arc
- Ball at peak of arc (appears smallest, highest confidence challenge)
- Ball near hoop (make/miss decision zone)
- Ball on floor / bouncing (post-shot, can be ignored but should not cause false makes)
- Multiple balls in frame (common in practice — detect closest/largest)

**Camera distances**
- Close range: paint shots (ball fills 15–25% of frame width)
- Mid range: mid-range shots (ball fills 8–15% of frame width)
- Long range: 3-point shots (ball fills 4–8% of frame width) — this is the hardest case

**Backgrounds**
- Empty gym wall / backboard
- Bleachers with spectators
- Cluttered gym equipment
- Outdoor court (Phase 2 stretch goal)

**Occlusions**
- Partial occlusion by rim, backboard, net
- Player hands partially covering ball

### Annotation Format

Standard YOLO format (`.txt` label files alongside images):
```
0 <cx> <cy> <width> <height>
```
All values normalised 0–1, relative to image dimensions. Single class index `0` = basketball.

### Recommended Public Datasets

These can be combined with your own footage for fine-tuning:

1. **Roboflow Universe — "Basketball" dataset** (`roboflow.com/universe`) — 5,000+ annotated basketball images, multiple scene types. Use as the base dataset.
2. **OpenImages v7** — Filter for `Sports ball` class, manually verify basketball subset (~2,000 useful images)
3. **Self-recorded footage** — Record 30–60 minutes of your own shooting sessions, extract frames at 5fps, annotate ~500–1,000 frames. This is the highest-value data because it matches your exact app conditions (mounting angle, device model, gym).

---

## 5. Training Pipeline (Offline)

This section is a reference for whoever trains the model. The app codebase does not include training scripts.

### Environment

```
Python 3.10+
ultralytics >= 8.0       # YOLOv8
coremltools >= 7.0       # Core ML export
torch >= 2.0 (CPU or CUDA)
```

### Steps

**1. Prepare data**
```bash
# Directory structure expected by Ultralytics
datasets/basketball/
  images/train/   # .jpg files
  images/val/
  images/test/
  labels/train/   # .txt YOLO annotation files
  labels/val/
  labels/test/
  data.yaml       # class names + paths
```

`data.yaml`:
```yaml
path: datasets/basketball
train: images/train
val: images/val
test: images/test
nc: 1
names: ['basketball']
```

**2. Fine-tune from pretrained weights**
```bash
yolo detect train \
  model=yolov8n.pt \
  data=datasets/basketball/data.yaml \
  epochs=100 \
  imgsz=416 \
  batch=16 \
  patience=20 \
  name=hooptrack_ball_v1
```

**3. Export to Core ML**
```python
from ultralytics import YOLO
import coremltools as ct

model = YOLO("runs/detect/hooptrack_ball_v1/weights/best.pt")
model.export(
    format="coreml",
    imgsz=416,
    nms=True,          # embed NMS in the model — simpler Swift wrapper
    conf=0.45,         # bake in the confidence threshold
    iou=0.45
)
# Output: best.mlpackage
```

**4. Validate the Core ML model**
```python
import coremltools as ct
import PIL.Image

mlmodel = ct.models.MLModel("best.mlpackage")
print(mlmodel.get_spec())  # verify input/output names

img = PIL.Image.open("test_frame.jpg").resize((416, 416))
result = mlmodel.predict({"image": img})
print(result)  # should show bounding boxes
```

**5. Rename and place**
```
HoopTrack/ML/BallDetector.mlpackage
```
Add to the Xcode project target. Ensure "Copy Bundle Resources" includes the `.mlpackage`.

---

## 6. `BallDetector.swift` Interface Specification

This is the Swift wrapper that must be built before the CVPipeline can be wired. The implementation is a `VNCoreMLRequest` wrapping the exported model.

```swift
// HoopTrack/ML/BallDetector.swift

import Vision
import CoreML
import AVFoundation

final class BallDetector {

    // MARK: - Configuration
    private let confidenceThreshold: Float

    // MARK: - Vision
    private let model: VNCoreMLModel
    private lazy var request: VNCoreMLRequest = {
        let req = VNCoreMLRequest(model: model)
        req.imageCropAndScaleOption = .scaleFit  // preserve aspect ratio
        return req
    }()

    // MARK: - Init
    init(confidenceThreshold: Float = HoopTrack.Camera.ballDetectionConfidenceThreshold) throws {
        // Load the bundled .mlpackage
        let mlModel = try BallDetectorModel(configuration: MLModelConfiguration()).model
        self.model = try VNCoreMLModel(for: mlModel)
        self.confidenceThreshold = confidenceThreshold
    }

    // MARK: - Detection
    /// Process a single camera frame. Returns nil if no ball detected above threshold.
    /// This method is called on the camera's sessionQueue — must NOT touch main actor.
    func detect(buffer: CMSampleBuffer) -> BallDetection? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let results = request.results as? [VNRecognizedObjectObservation],
              let best = results
                  .filter({ $0.confidence >= confidenceThreshold })
                  .max(by: { $0.boundingBox.area < $1.boundingBox.area })
        else { return nil }

        return BallDetection(
            boundingBox: best.boundingBox,
            confidence: best.confidence,
            frameTimestamp: CMSampleBufferGetPresentationTimeStamp(buffer)
        )
    }
}

// MARK: - CGRect convenience
private extension CGRect {
    var area: CGFloat { width * height }
}
```

**Key design decisions:**
- `imageCropAndScaleOption = .scaleFit` ensures aspect ratio is preserved when resizing 720p → 416×416, preventing distorted ball shapes that hurt confidence
- Selects the **largest** detection above threshold (not highest confidence) — when multiple balls are in frame, the closest (largest apparent size) is the one being shot
- Called on `sessionQueue` (not main actor) — must remain off main thread

---

## 7. Stub for Development & Testing

Before the real model exists, use this stub to build and test the CVPipeline end-to-end:

```swift
// HoopTrack/ML/BallDetectorStub.swift — only included in DEBUG builds

#if DEBUG
final class BallDetectorStub {
    private var frameCount = 0

    func detect(buffer: CMSampleBuffer) -> BallDetection? {
        frameCount += 1
        // Simulate a shot arc: ball appears at frame 60, rises, peaks at frame 90, descends
        guard frameCount % 180 > 60 && frameCount % 180 < 150 else { return nil }
        let progress = Double(frameCount % 180 - 60) / 90.0  // 0 → 1 over the arc
        let y = 0.2 + sin(progress * .pi) * 0.4              // arc from 0.2 → 0.6 → 0.2
        return BallDetection(
            boundingBox: CGRect(x: 0.45, y: y, width: 0.08, height: 0.08),
            confidence: 0.85,
            frameTimestamp: CMSampleBufferGetPresentationTimeStamp(buffer)
        )
    }
}
#endif
```

`CVPipeline` accepts a `BallDetectorProtocol` so the stub and real detector are interchangeable:

```swift
protocol BallDetectorProtocol {
    func detect(buffer: CMSampleBuffer) -> BallDetection?
}
```

---

## 8. Evaluation Criteria (Pre-Integration Gate)

The model must pass these checks before it is integrated into the app. Run them against the held-out test set.

| Metric | Minimum | Notes |
|--------|---------|-------|
| mAP@0.5 | ≥ 0.75 | YOLO standard metric on test set |
| Recall (ball in flight) | ≥ 0.85 | Subset of frames where ball is airborne |
| False positive rate | ≤ 0.05 | % of frames with no ball where detector fires |
| Inference latency (A15) | < 20ms | Matches `HoopTrack.Camera.maxProcessingLatencyMs` |
| Inference latency (A14) | < 35ms | Minimum supported device target |
| Memory footprint | < 50MB | Model loaded in memory during session |

**On-device profiling:**
Use Xcode Instruments → Core ML Instrument to verify latency. The 20ms target leaves headroom for the rest of the CVPipeline (calibration + state machine + zone classification) to fit within a 16.7ms frame budget at 60fps.

---

## 9. Coordinate System

Vision framework returns bounding boxes in **normalised image coordinates** with origin at **bottom-left**:

```
(0,1) ───────── (1,1)
  │                │
  │   Vision box   │
  │                │
(0,0) ───────── (1,0)
```

`CVPipeline` maps these to **court coordinates** (origin bottom-left of half-court) using the calibrated hoop reference from `CourtCalibrationService`. The detector does not need to know about court coordinates.

`BallDetection.boundingBox` centre point (`midX`, `midY`) is what the CVPipeline uses for trajectory tracking — the bounding box dimensions are used to infer approximate distance from camera.

---

## 10. File Checklist for Seamless Integration

When the model is trained and exported, the following must be in place before `CVPipeline` can be enabled:

- [ ] `HoopTrack/ML/BallDetector.mlpackage` — exported Core ML package, added to Xcode target
- [ ] `HoopTrack/ML/BallDetector.swift` — wrapper implementing `BallDetectorProtocol`
- [ ] `BallDetection` struct defined (can live in `BallDetector.swift`)
- [ ] `BallDetectorProtocol` defined (enables stub swapping)
- [ ] `HoopTrack.Camera.ballDetectionConfidenceThreshold` added to `Constants.swift`
- [ ] Inference latency verified < 20ms on target device via Instruments
- [ ] Test set mAP ≥ 0.75 confirmed before merging

Everything else in the Phase 2 plan (Steps 2–7) can be built and tested using `BallDetectorStub` without waiting for this checklist to be complete.
