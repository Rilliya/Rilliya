# Rilliya

Rilliya is a macOS audio routing workspace. This repository contains the
SwiftUI application; its reusable audio foundation lives in the sibling
RilliyaKit package.

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
