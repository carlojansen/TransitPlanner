# iOS

- `project.yml` (XcodeGen) erzeugt `TransitPlanner.xcodeproj` (nicht eingecheckt, nie von Hand bearbeiten).
- `TransitCore/` ist ein Swift Package ohne UI: API-Modelle, Netzwerk/Security, Location/Suche, Routing, Scheduling, SwiftData.
- `TransitPlanner/` ist die App.
- `TransitPlannerWidgets/` ist die Widget-Extension; sie liest nur den Snapshot aus der App Group (`TripSnapshotFile`), kein Netz.

```bash
cd ios && xcodegen generate
cd ios/TransitCore && swift test                         # offline, macOS
xcodebuild -project ios/TransitPlanner.xcodeproj -scheme TransitPlanner \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test   # gleiche Tests + Keychain im Simulator
```

Host und SPKI-Pins stehen ausschliesslich in `TransitCore/Sources/TransitCore/BackendConfig.swift`.
Der Bearer-Token steht nie im Code; er wird zur Laufzeit in die Keychain geschrieben (`KeychainSecretStore`).
