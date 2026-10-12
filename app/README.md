# Oculuxus app

The macOS app: native SwiftUI, macOS 14 or later. It is a Swift package,
so there is no checked-in Xcode project; open `app/Package.swift` in Xcode,
or build from the command line:

```sh
swift build          # or: xcodebuild -scheme Oculuxus -destination platform=macOS build
swift test
swift run Oculuxus
```

For now the app runs on sample data (`Sources/Oculuxus/Model/SampleData.swift`)
instead of the Go helper. The types in `Model/Protocol.swift` mirror the
messages in `proto/oculuxus/v1/oculuxus.proto` with the names swift-protobuf
generates, so they can be replaced by the generated code when the app starts
talking to the helper.

| Directory | What it is |
| --- | --- |
| `Model/` | Protocol mirrors, the sample projects and a toy highlighter for them. |
| `Navigator/` | The Navigator window: project picker, project packages, dependencies by module, the standard library. |
| `Workspace/` | Workspace windows: package content pane, source viewer (TextKit 2 `NSTextView`), history. |
| `Settings/` | Font and color scheme settings and their popover. |
