# Signet 🖋️
> **Native macOS Sideloading & IPA Resigning Tool**

A lightweight, modern, native macOS alternative to Sideloadly and AltStore built specifically for Apple Developer Program members and sideloading enthusiasts.

Signet bypasses the need for third-party anisette servers, Apple ID password prompts, and 2FA SMS hassles by working entirely with standard local Apple Developer Certificates (`.p12`) and Provisioning Profiles (`.mobileprovision`).

---

## ✨ Features

- **Native macOS Liquid Glass Design**: Built with pure SwiftUI for macOS 14+ (Sonoma, Sequoia).
- **365-Day Uninterrupted Sideloading**: Designed for paid Apple Developer accounts with full validity inspection.
- **Embedded `zsign` Signing Engine**: Fast C++ signing with Mach-O parsing, dynamic entitlements, and `.zsign_cache` support.
- **Tweak & Dylib Injection**: Drag-and-drop external `.dylib` and `.framework` files into the IPA.
- **Bundle ID & Name Customization**: Easily change the bundle identifier or app display name on the fly.
- **Dual Device Discovery & Deployment**:
  - **Apple CoreDevice (`devicectl`)**: First-class support for modern iOS 17+ / 18+ devices.
  - **`libimobiledevice` (`idevice_id`, `ideviceinfo`, `ideviceinstaller`)**: Legacy and standard iOS support.
- **Real-time Process Terminal**: Live stdout/stderr log streaming with color-coded severity levels and autoscroll.
- **Secure Keychain Storage**: Protects `.p12` passphrases inside macOS Keychain Services (`kSecClassGenericPassword`).

---

## 🏗️ Architecture

```
Signet/
├── Package.swift
├── Sources/
│   └── Signet/
│       ├── App/
│       │   └── SignetApp.swift
│       ├── Models/
│       │   ├── Device.swift
│       │   ├── CertificateInfo.swift
│       │   ├── ProvisioningProfileInfo.swift
│       │   ├── SigningConfiguration.swift
│       │   ├── SigningState.swift
│       │   ├── LogMessage.swift
│       │   └── IPAMetadata.swift
│       ├── Services/
│       │   ├── BinaryManager.swift
│       │   ├── ProcessRunner.swift
│       │   ├── CredentialService.swift
│       │   ├── DeviceService.swift
│       │   ├── SignerService.swift
│       │   ├── InstallerService.swift
│       │   └── IPAManager.swift
│       ├── ViewModels/
│       │   └── SignetAppState.swift
│       ├── Views/
│       │   ├── MainView.swift
│       │   ├── Components/
│       │   │   ├── DevicePickerView.swift
│       │   │   ├── CertificateStatusCard.swift
│       │   │   ├── IPADropZoneView.swift
│       │   │   ├── CustomizationOptionsView.swift
│       │   │   ├── LogConsoleView.swift
│       │   │   └── ActionFooterView.swift
│       │   └── Settings/
│       │       └── SettingsView.swift
│       └── Resources/
│           ├── bin/zsign (Standalone static binary)
│           └── Scripts/build_zsign.sh
└── Tests/
    └── SignetTests/
        └── SignetTests.swift
```

---

## 🚀 Getting Started

### Prerequisites

- macOS 14.0 or newer
- Xcode 15+ / Command Line Tools (`xcode-select --install`)
- *(Optional for legacy devices)* Homebrew `libimobiledevice`:
  ```bash
  brew install libimobiledevice ideviceinstaller
  ```

### Building & Running

1. Clone the repository:
   ```bash
   git clone https://github.com/hasanalbayrak/signet.git
   cd signet
   ```

2. Build and run tests:
   ```bash
   swift build
   swift test
   ```

3. Launch the application:
   ```bash
   swift run
   ```
   Or open the folder directly in Xcode (`open Package.swift`) and click **Run**.

---

## 🔐 Credentials Setup

1. Open **Signet Preferences** (Click the ⚙️ icon or **Configure** on the certificate card).
2. Select your Apple Development Certificate (`.p12`) and enter your export password.
   - The password is saved securely to your local macOS Keychain.
3. Select your Provisioning Profile (`.mobileprovision`).
   - Wildcard profiles (`*`) are highlighted with a badge and automatically strip incompatible extensions if selected.
4. Signet validates the certificates and displays remaining days (e.g. `365 days remaining`).

---

## 📱 Developer Mode on iOS 16+

If installing an app fails with a Developer Mode error:
1. Open **Settings** on your iOS device.
2. Navigate to **Privacy & Security** > **Developer Mode**.
3. Toggle **Developer Mode** ON and restart the device when prompted.

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.
