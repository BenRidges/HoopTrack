# Roboflow Model Integration

How to swap in a Roboflow (or any Core ML) ball detection model.

## 1. Export from Roboflow

1. Find or train a basketball detection model at [roboflow.com](https://roboflow.com)
   - Search Roboflow Universe for public "basketball" datasets if you don't have your own
2. Click **Export Model** → select format **CoreML**
3. Download the `.mlpackage` (preferred) or `.mlmodel` file
4. Note the **class label** used (shown under Classes — typically `"basketball"` for custom models, `"sports ball"` for COCO-trained models)

## 2. Add to Xcode

1. Drag the `.mlpackage` into `HoopTrack/HoopTrack/ML/` in the Xcode Project Navigator
2. In the add-files dialog, ensure **Add to target: HoopTrack** is checked
3. Note the filename without extension (e.g. `BasketballDetector`)

## 3. Update the Factory

Open `HoopTrack/ML/BallDetectorFactory.swift` and update the `active` property:

```swift
static var active: BallDetectorConfiguration {
    #if DEBUG
    return .stub   // keeps synthetic arc in simulator/debug builds
    #else
    return .bundled(
        modelName: "BasketballDetector",  // .mlpackage filename, no extension
        targetLabel: "basketball"         // must match the Roboflow class label exactly
    )
    #endif
}
```

That's the only code change required. No other files need to be touched.

## 4. Verify

- Build and run in **Release** scheme to exercise the bundled path
- If the model file is missing or fails to load, the app automatically falls back to manual Make/Miss buttons — it will never crash

## Notes

- The factory currently looks for `.mlpackage`. If your export is `.mlmodel`, update the `withExtension:` argument in `BallDetectorFactory.make(_:)` from `"mlpackage"` to `"mlmodel"`
- To test a second model without removing the first, add both files and change `modelName` in `active` — no other changes needed
- Confidence threshold is set in `Constants.swift` at `HoopTrack.Camera.ballDetectionConfidenceThreshold` (default `0.45`)
