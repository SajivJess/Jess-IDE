# MuseFlow — Mobile Android Client

Native Android client for **MuseFlow** (Mobile AI Pair Programming & Coding IDE), built with Flutter.

MuseFlow gives developers full mobile control over autonomous coding agents executing on a real development host, combined with conversational voice input, visual UI mockups, and rigorous human-in-the-loop diff approvals.

---

## Key Features

1. **Autonomous Coding Loop Control:**
   - Submit tasks via chat or voice.
   - Inspect live agent reasoning, file operations, and test verification output in real-time.
   - Guarded human-in-the-loop review: tasks pause at `APPROVAL_REQUIRED` until you explicitly accept or reject the proposed Git diff.

2. **Conversational Voice Input (Muse Voice Transcribe 1.0):**
   - Push-to-talk recording with haptic feedback and real-time audio level monitoring.
   - Server-side transcription supporting conversational English, Tamil, and technical vocabulary.
   - Transcripts populate the chat composer for review before sending.

3. **AI UI Suggestions (Muse Image 1.0):**
   - Autonomous UI mockup generation based on natural language screen descriptions.
   - Inline visual preview with one-tap **"Code This Design"** dispatch to the primary Muse Spark agent.

4. **Interactive Git Review & Workspace Management:**
   - Per-file diff stats (+lines / -lines).
   - Unified color-coded diff viewer with chunk headers.
   - Switch branches (`main`, feature branches) directly from the mobile interface.

5. **Hardened Network Security:**
   - Dedicated `network_security_config.xml` blocks non-local cleartext HTTP.
   - Bearer access tokens are never logged in debug outputs or URLs.
   - In-app host configuration with instant ping latency probe and cleartext connection warnings.

---

## Architecture Layout

```
jess_app/
├── android/
│   └── app/src/main/
│       ├── AndroidManifest.xml          # Enforces network security config
│       └── res/xml/network_security_config.xml # Restricts cleartext to loopback
├── lib/
│   ├── models/                          # Strongly-typed data models (Chat, Project, Task, Diff)
│   ├── screens/
│   │   ├── chat/                        # Conversational timeline & voice push-to-talk
│   │   ├── dashboard/                   # Recent projects, active tasks, quick stats
│   │   ├── diff_review/                 # Unified Git diff viewer & approval controls
│   │   ├── projects/                    # Project list, creation, & overview
│   │   ├── settings/                    # Host configuration, latency test, security notices
│   │   └── workspaces/                  # File browser & terminal output viewer
│   ├── services/
│   │   ├── auth_api_service.dart        # JWT auth & token storage
│   │   ├── chat_stream_service.dart     # WebSocket stream listener & auto-reconnect
│   │   ├── task_stream_service.dart     # Safe task event streaming without token leaks
│   │   ├── voice_transcribe_service.dart# Audio recording & backend transcription
│   │   └── ui_suggestions_service.dart  # Muse Image mockup client
│   ├── theme/                           # Modern dark-mode IDE styling & typography
│   └── widgets/                         # Reusable UI components (buttons, badges, bubbles)
└── test/                                # 30 automated unit & widget tests
```

---

## Local Development & Testing

### 1. Prerequisites
- **Flutter SDK:** 3.24+ (Channel stable)
- **Android SDK:** API 34+
- Connected Android device (with USB debugging enabled) or Android Emulator

### 2. Run Test Suite
```bash
flutter test
```
*All 30 automated tests cover audio recording checks, WebSocket timeline reconciliation, message deduplication, chat UI components, and navigation shells.*

### 3. Build & Run on Device
To run with USB port-forwarding (fastest):
```bash
# In terminal on host machine:
adb reverse tcp:8000 tcp:8000

# Run Flutter app:
flutter run
```

### 4. Build Release APK
To compile a standalone release APK:
```bash
flutter build apk --release
```
To bake in a custom production API endpoint:
```bash
flutter build apk --release --dart-define=MUSEFLOW_API_URL=https://your-domain.com/api/v1
```
The output APK will be placed in `build/app/outputs/flutter-apk/app-release.apk`.
