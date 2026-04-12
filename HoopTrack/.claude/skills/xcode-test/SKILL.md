---
name: xcode-test
description: Run HoopTrack tests. Pass a test class name to run just that class, or omit to run the full suite.
disable-model-invocation: true
---

Run the HoopTrack test suite via xcodebuild.

## Usage

```
/xcode-test                          # run all tests
/xcode-test CourtZoneClassifierTests # run a specific class
```

## Command

```bash
# All tests
xcodebuild test \
  -project HoopTrack/HoopTrack.xcodeproj \
  -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Single class (replace CLASS with the argument)
xcodebuild test \
  -project HoopTrack/HoopTrack.xcodeproj \
  -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HoopTrackTests/CLASS
```

## Available test classes

- `BadgeScoreCalculatorTests`
- `CVPipelineStateTests`
- `CourtZoneClassifierTests`
- `DataServiceExportTests`
- `DribbleCalculatorTests`
- `ExportServiceTests`
- `GoalUpdateServiceTests`
- `ShotScienceCalculatorTests`
- `SkillRatingCalculatorTests`
