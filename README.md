# Signet 🖋️
> **Native macOS Sideloading & IPA Resigning Tool**

A lightweight, modern, native macOS alternative to Sideloadly and AltStore built specifically for Apple Developer Program members and sideloading enthusiasts.

Signet eliminates the friction of traditional sideloading:
- **1-Click Apple Developer Auto-Provisioning:** Log in via official App Store Connect API Key, select your developer team, and Signet automatically registers your device, creates/downloads your 365-day certificate, and generates a Wildcard Provisioning Profile.
- **Manual Mode Available:** Alternatively, drag-and-drop standard `.p12` certificates and `.mobileprovision` files.
- **No Anisette / No 2FA Hassle:** No third-party cloud servers, no account password theft risk, and no 7-day expiration limits.

---

## ✨ Features

- **Apple Developer Account Auto-Provisioning**:
  - Connect via official App Store Connect API Key (`.p8`).
  - Automatic Apple Developer team selection and verification.
  - Automatic iOS device UDID registration in Apple Developer Portal.
  - Generates 365-day Development Certificates and Wildcard Provisioning Profiles (`*`).
- **Native macOS Liquid Glass Design**: Built with pure SwiftUI for macOS 14+ (Sonoma, Sequoia).
- **Embedded `zsign` Signing Engine**: Fast C++ signing with Mach-O parsing, dynamic entitlements, and `.zsign_cache` support.
- **Tweak & Dylib Injection**: Drag-and-drop external `.dylib` and `.framework` files into the IPA.
- **Bundle ID & Name Customization**: Easily change the bundle identifier or app display name on the fly.
- **Dual Device Discovery & Deployment**:
  - **Apple CoreDevice (`devicectl`)**: First-class native support for iOS 17+ and iOS 18+ devices.
  - **`libimobiledevice` (`idevice_id`, `ideviceinfo`, `ideviceinstaller`)**: Legacy and standard iOS support.
- **Real-time Process Terminal**: Live stdout/stderr log streaming with color-coded severity levels and autoscroll.
- **Secure Keychain Storage**: Protects `.p12` passphrases and API keys inside macOS Keychain Services (`kSecClassGenericPassword`).
- **Automated GitHub Releases**: Built-in GitHub Actions CI/CD pipeline packages `.app` bundles and publishes releases on tag push.

---

## 🏗️ Architecture

```
Signet/
├── .github/
│   └── workflows/
│       └── release.yml            # Automated GitHub Actions Release Workflow
├── Package.swift
├── Sources/
│   └── Signet/
│       ├── App/
│       │   └── SignetApp.swift
│       ├── Models/
│       │   ├── AppleAccountModels.swift   # Teams, ASC credentials & auto-provision state
│       │   ├── Device.swift
│       │   ├── CertificateInfo.swift
│       │   ├── ProvisioningProfileInfo.swift
│       │   ├── SigningConfiguration.swift
│       │   ├── SigningState.swift
│       │   ├── LogMessage.swift
│       │   └── IPAMetadata.swift
│       ├── Services/
│       │   ├── AppleDeveloperService.swift # JWT generation, Device Reg, Cert & Profile Auto-Gen
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

2. Run the test suite:
   ```bash
   swift test
   ```

3. Launch the application:
   ```bash
   swift run
   ```
   Or open the folder directly in Xcode (`open Package.swift`) and click **Run**.

---

## 🔐 Credentials Setup

### Option 1: Direct Apple ID Login with 2FA (Easiest)
1. Open **Preferences** (Click ⚙️ in the top bar).
2. Go to **Apple ID (Direct + 2FA)** tab.
3. Enter your **Apple ID Email** and **Password** -> Click **Sign In with Apple ID**.
4. When prompted, enter the **6-digit 2FA verification code** sent to your iPhone/iPad/Mac.
5. Select your **Developer Team** from the dropdown.
6. Click **⚡ 1-Click Auto Provision (365 Days)**: Signet registers your connected iPhone, requests the development certificate from Apple, generates a Wildcard profile, packages the `.p12`, and stores credentials in macOS Keychain!

### Option 2: App Store Connect API Key (.p8)
1. Open **Preferences** > **API Key (.p8)** tab.
2. Enter your **Key ID**, **Issuer ID**, and drop your **AuthKey_XXXXX.p8** file.
   > *To generate an API key, visit [developer.apple.com](https://developer.apple.com) > App Store Connect > Users and Access > Integrations > Generate API Key.*
3. Click **Connect & Verify API Key** and select your Team.
4. Click **1-Click Auto Provision via API Key**.

### Option 3: Manual .p12 & Provisioning Profile
1. Open **Preferences** > **Manual (.p12 / Profile)** tab.
2. Select your `.p12` file and enter your password.
3. Select your `.mobileprovision` file.
4. Signet verifies validity and displays the remaining days count.

---

## 📦 Automated GitHub Release Workflow

Signet includes a full GitHub Actions workflow located at `.github/workflows/release.yml`.

To create a new release on GitHub:
```bash
git tag v1.0.0
git push origin v1.0.0
```

The GitHub Actions runner will:
1. Spin up a `macos-14` Apple Silicon runner.
2. Build standalone `zsign` with static OpenSSL.
3. Run the complete unit test suite (`swift test`).
4. Compile the release binary and bundle a signed `Signet.app`.
5. Package `Signet-macOS-AppleSilicon.zip`.
6. Automatically publish a new GitHub Release with release notes and downloadable assets.

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.
