# System Display

**System Display** is an Android application designed to present a simple black fullscreen display with centered white text.

## Overview

The application provides a minimal, portrait-oriented display interface. It is intended for controlled device-display scenarios, demonstrations, and testing.

## Features

- **Black Fullscreen Display:** Shows a black background with centered white text.
- **Portrait Orientation:** Keeps the application interface in portrait orientation.
- **Keep Screen On:** Requests that the screen remain on while the application is active.
- **Immersive Interface:** Hides the Android status and navigation bars while the application has focus.
- **Lock Task Mode Attempt:** Attempts to enter Android Lock Task Mode; availability depends on device configuration and authorization.
- **Foreground Service:** Uses a foreground service to help maintain application activity.
- **Restart and Scheduling Mechanisms:** Includes mechanisms that attempt to relaunch the application after certain system events and through scheduled tasks.
- **Signed APK Output:** The build process produces a signed Android APK.

## Application Specifications

| Specification | Details |
|---|---|
| Application Name | System Display |
| Android Package ID | `com.system.display` |
| Version | 1.0 |
| Minimum Android Version | Android 5.0 (API 21) |
| Target Android Version | Android 9 (API 28) |
| Interface | Black fullscreen screen with centered white text |
| Orientation | Portrait |
| Main Text | `Display` |
| Output APK | `SystemDisplay.apk` |

## Runtime Behavior

- The application opens a fullscreen black screen and displays the configured text.
- It requests that the display remain on while the interface is active.
- It attempts to restore the fullscreen interface when the window regains focus.
- Background components attempt to restart or bring the application forward after selected events.

Behavior may differ across Android versions and device manufacturers. Modern Android restrictions may prevent background components from launching an activity at all times.

## Permissions and System Access

The application declares permissions associated with:
- Receiving boot-completion broadcasts.
- Running a foreground service.
- Keeping the device CPU awake.
- Requesting exemption from battery optimizations.
- Scheduling alarms.
- Posting notifications.
- Managing keyguard-related display behavior.

Some functions require user approval, device-owner configuration, or compatible Android behavior. Declared permissions do not guarantee that every feature will work on every device.

## Compatibility Notes

- Designed for Android devices supporting API 21 or later.
- Actual behavior depends on Android version, manufacturer-specific power management, and system policies.
- Lock Task Mode is not equivalent to a fully managed kiosk configuration on every device.
- The application cannot reliably block all physical or system-level buttons on ordinary Android devices.

## Disclaimer

Use this application only on devices you own or are authorized to manage. Review its behavior and permissions before installation.

## License

Add a license file to this repository if you intend to distribute the project as open source.
