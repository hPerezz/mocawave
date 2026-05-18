# Mocawave

Mocawave is a macOS audio player and analyzer built with SwiftUI, AppKit, AVFoundation, Accelerate, and StoreKit. It opens local audio files, plays them back, renders waveform/spectrogram views, estimates BPM and musical key, and exposes Pro-only analysis such as RGB waveform, LUFS, peak dB, and quality estimation.

Supported audio document types are configured in `App-Info.plist`: MP3, WAV, AAC, and M4A.

## Project Overview

- Platform: macOS 12.0+
- UI: SwiftUI with small AppKit bridges where direct `NSWindow` or mouse tracking access is needed
- Audio playback: `AVAudioEngine`, `AVAudioPlayerNode`, and `AVAudioFile`
- DSP: Accelerate/vDSP FFT and vector operations
- Purchases: StoreKit 2, product id `mocawave.pro.lifetime`
- Cache: JSON cache in `Application Support/mocawave/audio_cache.json`
- Tests: XCTest unit tests for waveform-analysis scheduling behavior

## Architecture

Mocawave is organized around a main SwiftUI view backed by a single playback/analysis view model. Heavy audio analysis is delegated to actors and pure analyzer modules so the UI stays responsive.

```text
MocawaveApp
  -> ContentView
      -> AudioPlayerViewModel
          -> AVAudioEngine / AVAudioPlayerNode
          -> AudioCache
          -> WaveformAnalysisCoordinator
              -> WaveformAnalyzer
          -> BPMAnalyzer4 / KeyAnalyzer
          -> LUFSMeter
      -> ProEntitlementStore
          -> StoreKitProStoreBackend
```

The high-level flow is:

1. `MocawaveApp` starts the macOS app and injects `ProEntitlementStore`.
2. `ContentView` owns an `AudioPlayerViewModel` and renders the player UI.
3. A user opens or drops an audio file.
4. `AudioPlayerViewModel` validates the file, starts playback, keeps sandbox access alive, and starts/cancels analysis tasks.
5. Cached results are loaded from `AudioCache` when valid.
6. Missing analysis runs through `WaveformAnalysisCoordinator`, `WaveformAnalyzer`, `BPMAnalyzer4`, and `KeyAnalyzer`.
7. UI state updates through `@Published` properties on the main actor.

## Components

### App and Windowing

| Component | Role |
| --- | --- |
| `MocawaveApp.swift` | App entry point. Configures AppKit activation, creates the main `WindowGroup`, prepares StoreKit state, and forwards Finder file-open events to `AudioOpenCoordinator`. |
| `App-Info.plist` | Bundle metadata and document type registration for supported audio files. |
| `Mocawave.entitlements` | macOS sandbox entitlements. Allows read-only access to user-selected files. |
| `WindowConfigurator.swift` | SwiftUI/AppKit bridge that exposes the underlying `NSWindow` for one-time window configuration. |
| `AudioOpenCoordinator.swift` | Routes external open-file events to the active window/view model. Stores a pending URL if the app receives a file before the window is registered. |

### UI Layer

| Component | Role |
| --- | --- |
| `ContentView.swift` | Main player interface. Renders top-bar metrics, playback controls, waveform/spectrogram areas, Pro gates, debug window, drag-and-drop import, and fixed-height window behavior. |
| `WaveformView.swift` | Waveform rendering primitives. Includes plain waveform, RGB waveform, pending/loading waveform views, resampling, mouse tracking, hover lines, and seek gestures. |
| `SpectrogramView.swift` | Renders a `CGImage` spectrogram with played-region dimming, playhead, hover line, and seek gesture. |
| `ProPaywallSheet.swift` | Pro upsell and purchase/restore UI. Uses `ProEntitlementStore` state and fallback product copy when App Store product loading is unavailable. |

### Playback and State

| Component | Role |
| --- | --- |
| `AudioPlayerViewModel.swift` | Main orchestration layer. Opens files, manages `AVAudioEngine`, play/pause/seek state, analysis task lifecycle, real-time meters, cached analysis, Pro feature gating, and debug logs. It is `@MainActor` because it drives UI state. |
| `LUFSMeter.swift` | Thread-safe real-time LUFS and peak dB meter. Processes buffers from an audio-engine tap and implements ITU-R BS.1770-style K-weighting with a short-term window. |
| `AudioCache.swift` | Actor-backed persistent cache for waveform samples, BPM, key, quality, and RGB waveform data. Uses file size and modification date to validate entries. |

### Analysis Pipeline

| Component | Role |
| --- | --- |
| `WaveformAnalysisCoordinator.swift` | Actor that deduplicates identical analysis requests, serializes expensive waveform-family work per URL, and provides cancellation methods for waveform, RGB waveform, spectrogram, and quality jobs. |
| `WaveformAnalyzer.swift` | Core waveform/spectrum analyzer. Decodes audio into mono PCM, computes waveform samples, RGB waveform columns, spectrogram data, and quality classification. Uses Accelerate FFT/vDSP. |
| `BPMAnalysis/EllisDPBPMAnalyzer.swift` | Primary BPM analyzer (`BPMAnalyzer4`). Implements an Ellis-style onset envelope, tempo estimation, dynamic-programming beat tracking, and BPM folding. |
| `BPMAnalysis/KeyAnalyzer.swift` | Musical key analyzer. Builds spectral/HPCP features across segments, scores major/minor candidates, and returns key plus Camelot notation. |
| `BPMAnalysis/EnsembleBPMAnalyzer.swift` | Alternative/legacy BPM analyzer using multiple onset and tempo-estimation strategies. |
| `BPMAnalysis/StemBPMAnalyzer.swift` | Alternative/legacy BPM analyzer with stem/frequency-oriented processing helpers. |
| `BPMAnalysis/librosa_bpm_analyzer.py` and `BPMAnalyzer3.py` | Python analyzer scripts retained as auxiliary/legacy BPM analysis resources. |

### Pro and StoreKit

| Component | Role |
| --- | --- |
| `ProEntitlementStore.swift` | StoreKit-facing entitlement model. Fetches products, observes transaction updates, checks current entitlements, purchases/restores Pro, and exposes UI-ready purchase state. |
| `ProFeatures.swift` | Central Pro feature switch. Currently enables a development override through `developmentOverrideFlag`. |
| `Mocawave Pro.storekit` | Local StoreKit configuration for testing the non-consumable Pro lifetime purchase. This is the file referenced by the shared Xcode scheme. |

### Assets and Tests

| Component | Role |
| --- | --- |
| `Assets.xcassets` | App icon and accent color assets. |
| `MocawaveTests/MocawaveTests.swift` | Unit tests for `WaveformAnalysisCoordinator`, including request deduplication, per-URL serialization, and cancellation of queued work. |
| `MocawaveUITests` | Default UI test target scaffold. |
| `Mocawave 2026-03-19 23-58-45/` | Exported `.app` bundle committed as an artifact snapshot. It is not part of the source build graph. |

## Data and Control Flow

### Opening a File

1. The user opens a file through Finder, drag-and-drop, or the import UI.
2. `AudioOpenCoordinator` or `ContentView` calls `AudioPlayerViewModel.open(url:)`.
3. The view model checks the extension, starts security-scoped access, resets old playback/analysis state, opens `AVAudioFile`, starts `AVAudioEngine`, and begins playback.
4. `loadOrAnalyze(url:)` checks `AudioCache`.
5. Cached data is applied immediately, or missing analysis is scheduled.

### Analysis Scheduling

`AudioPlayerViewModel` owns lightweight task handles for each analysis type. CPU-heavy work runs off the main actor:

- waveform, RGB waveform, spectrogram, and quality go through `WaveformAnalysisCoordinator`
- BPM runs through `BPMAnalyzer4`
- key detection runs through `KeyAnalyzer`

The coordinator prevents duplicate identical work and serializes expensive operations for the same file URL. When the user opens a different file or toggles features off, the view model cancels stale tasks and asks the coordinator to cancel matching URL-scoped work.

### Pro Features

Pro access is exposed through `ProEntitlementStore.effectiveProAccess`. The UI and view model use it to gate:

- RGB waveform
- LUFS and peak dB meters
- audio quality analysis

StoreKit is wrapped behind `ProStoreBackend`, which makes the entitlement store testable and allows `UnavailableProStoreBackend` to explain why StoreKit is unavailable when the app is not running as a real `.app` bundle.

## Development

Open `Mocawave.xcodeproj` in Xcode and run the `Mocawave` scheme.

The project is an Xcode project, not a Swift Package, so `swift build` will not work from the repository root. Command-line builds require a full Xcode developer directory selected, for example:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -project Mocawave.xcodeproj -scheme Mocawave build
```

Run unit tests with:

```sh
xcodebuild -project Mocawave.xcodeproj -scheme Mocawave test
```

## Notes for Future Work

- Keep `AudioPlayerViewModel` focused on orchestration. Move new heavy DSP work into analyzer modules or actor-backed services.
- Bump `AudioCache.cacheVersion` when cached analysis formats or algorithms change.
- Keep Pro-gated state changes flowing through `ProEntitlementStore` and `ProFeatures`.
- Avoid running expensive audio analysis directly on the main actor; route it through task/coordinator boundaries.
