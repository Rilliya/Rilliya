# Performance

Rilliya optimizes in this order: correctness and safety, runtime performance,
then binary and memory footprint. Measurements use optimized builds and are
repeated before and after a change; debug-build figures are not accepted as
release baselines.

## Baseline

The August 15, 2026 baseline was measured on an Apple M4 Pro Mac with 24 GB of
memory. Values vary with window size, display scale, OS version, and graph
contents, so comparisons need to keep those inputs fixed.

| Workload | Result |
| --- | --- |
| Normal Release, idle | 0.0–0.1% CPU, 138 MB physical footprint, 106 MiB RSS |
| 100-node graph, continuously panning | approximately 12–25% CPU after optimization; approximately 100% before |
| Same-window 4× to 2× MSAA comparison | graphics allocation 98 MB to 49 MB; total footprint 187 MB to 131 MB |
| Universal Release app | 25,832 KiB, including a 43,200-byte precompiled Metal library |
| Universal executable | 26,396,920 bytes |
| RilliyaKit arm64 Release static archive | 761,800 bytes before consumer dead stripping |

The separate 42 MiB dSYM is a debugging artifact and is not part of the app
bundle. The normal canvas renders on demand and pauses completely while idle.

## Routing stress profile

The profiling build contains a deterministic graph generator and camera motion
only when compiled with the `PROFILE` condition. It is absent from normal Debug
and Release behavior.

Profile 50 Application Audio and Visualizer pairs with:

```sh
./scripts/profile-routing.sh 50
```

The script builds an optimized native-architecture app, launches only the app it
built, records `footprint` and a five-second `sample`, then terminates that
process. Results remain under `.build/Profiles/` for before-and-after comparison.

## Current safeguards

- Metal source compiles into `default.metallib` at build time, and a unit test
  verifies that every required shader function is present.
- Metal API Validation and Shader Validation are part of renderer smoke testing.
- Viewport motion remains inside the Metal backend during gestures and persists
  to workflow state only when the interaction ends.
- The renderer culls nodes and edges outside an overscanned visible world rect.
- Dynamic meter text uses reusable glyphs in fixed-size texture atlases rather
  than caching every changing numeric string.
