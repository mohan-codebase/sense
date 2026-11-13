# Sense for iOS

A native iPhone and iPad device monitor, adapted from Sense for Mac. Requires iOS 17+ and Xcode 15+.

Open `Sense.xcodeproj`, select the **Sense** scheme, and run on an iPhone simulator. For a physical iPhone, the project is configured for Mohan's existing development team and automatic signing with bundle ID `com.mohanavenkatesh.sense`. Choose your device and Run. Other developers should select their own team under **Signing & Capabilities**. Command-line installation uses Xcode's automatic provisioning with the existing signed-in account.

## Readings

- Battery percentage, charging state, and Low Power Mode from UIKit/ProcessInfo.
- System thermal pressure: Nominal, Fair, Serious, or Critical. This is not a Celsius temperature.
- Filesystem capacity and free space, refreshed every 30 seconds.
- Physical RAM capacity. This is not live system-wide memory usage.
- Sense's own physical memory footprint and session history.
- Wi-Fi (`en0`) and cellular (`pdp_ip*`) interface download/upload counters and rates. These are passive interface readings, not an Internet speed test. Counter resets start a new baseline; loopback and VPN/tunnel interfaces are excluded to avoid obvious duplicate counts.
- Connection status, Low Data Mode, metered connections, and IPv6 availability.

No other apps' process usage, GPU utilization, battery health/cycle counts, or exact temperature sensors are claimed. CPU core count is shown in device details. The app does not use private APIs, execute shell commands, connect to a service, or upload readings.

Readings pause when the app becomes inactive/backgrounded. History lives in memory and is limited to 15 minutes / 900 samples. Settings support 1, 2, or 5-second sampling, 2/15-minute chart windows, and System/Dark/Light appearance. Low Power Mode uses at least a 5-second sampling interval.

The simulator may have no battery reading, and its RAM, thermal, storage, and interface values describe the simulator host where available. The app displays this distinction. Physical-device readings still need to be validated on an actual iPhone.

## Build and tests

The Xcode project is committed as an ordinary project; XcodeGen is only needed to regenerate it after editing `project.yml`:

```sh
xcodegen generate
xcodebuild -project Sense.xcodeproj -scheme Sense -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Sense.xcodeproj -scheme Sense -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Sense.xcodeproj -scheme Sense -destination 'generic/platform=iOS' -derivedDataPath build-device CODE_SIGNING_ALLOWED=NO build
```

Unit tests check network-rate deltas, counter resets and pauses, unavailable storage, storage fractions, and bounded session history. The device build is unsigned; installation on a physical device requires signing.

The app icon reuses the Mac app's vector SenseMark, rendered on an opaque iOS icon background. `PrivacyInfo.xcprivacy` declares disk-space access for on-device display (`85F4.1`) and app-only settings (`CA92.1`). No telemetry or account system is included.

API references: [Battery readings](https://developer.apple.com/documentation/uikit/uidevice/batterylevel), [thermal state](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property), [privacy API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
