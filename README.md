# Rilliya

Rilliya is a macOS audio routing workspace. This repository contains the
SwiftUI application; its reusable audio foundation lives in the sibling
RilliyaKit package.

The application opens directly into the FlowingDayUI routing canvas. Application
Audio nodes capture installed macOS applications, Input Audio nodes capture
physical or virtual Core Audio input devices, and System Output nodes capture a
specific output device or follow the system default. Visualizer and Peak Level
nodes can inspect any source. Rilliya shares one native capture among nodes using
the same source, including consumers in different workflows.

Rilliya scans the standard user, local, and system Applications directories and
overlays live running state from `NSWorkspace`. Input-device capture requests
microphone permission only when a connected Input Audio node needs to run.

Virtual Input and Virtual Output nodes use Rilliya's clean-room Audio Server
plug-in. Release builds include a separately signed and notarized installer in
the application bundle. The Preferences window opens that package through the
standard macOS Installer; installation requires an administrator password and
a restart before Core Audio loads the driver. Development builds deliberately
do not bundle an unsigned installer.

The initial application foundation requires macOS 14.2 or later, Xcode, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). It also expects these local
Swift packages beside this checkout:

```text
workspace/
├── Rilliya/
├── RilliyaKit/
└── flowing-day-ui/
```

## Build and run

Generate the Xcode project and build the app with:

```sh
./scripts/build.sh
```

Launch the resulting debug app with:

```sh
./scripts/run.sh
```

The default build uses an ad hoc signature. For a stable local Apple
Development signature, copy `.rilliya-signing.example` to
`.rilliya-signing.local`, then provide values available in your local
developer account and login keychain. The local file and generated Xcode
project are ignored by Git. Explicit signing environment variables take
precedence over the local file.

## Test

Run the application unit tests with:

```sh
./scripts/test.sh
```

The test entry point disables code signing and uses a repository-local
Derived Data directory. Tests in this repository cover application-owned
state and presentation; reusable audio behavior belongs in RilliyaKit tests.

Run formatting, property-list validation, unit tests, and a debug build with:

```sh
./scripts/check.sh
```

Apply the repository's Swift formatting rules with:

```sh
./scripts/format.sh
```

## Distribution

The release workflow builds Apple Silicon and Intel application and driver
artifacts, assembles Universal variants, signs the driver with a Developer ID
Application identity, and signs its installer package with a Developer ID
Installer identity. The package installs only:

```text
/Library/Audio/Plug-Ins/HAL/RilliyaVirtualAudioDriver.driver
```

The driver installer and all three application disk images are notarized before
the workflow creates a GitHub prerelease. The application embeds the same
stapled installer that is also published as a standalone release asset.

The shipped audio driver has no third-party runtime dependency. The application
uses RilliyaKit and FlowingDayUI from the Rilliya organization, Apple platform
frameworks, and Apple's Swift Atomics package through RilliyaKit. XcodeGen is a
development-time project generator and is not included in the application.

## License

Rilliya is available under the Apache License 2.0. See [LICENSE](LICENSE).
