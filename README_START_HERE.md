# AJ Face Attendance — Android + Python source package

## Included
- **android_app/**: Flutter 5-tab blue-and-white Android interface, exact user-supplied AJ logo, embedded camera scan, registration, face enrollment, training, dashboard and reports.
- **backend/**: Python FastAPI + OpenCV LBPH + SQLite local prototype with registration, face training, scanning, daily reports and CSV export.

## Important current status
This is **source code**, not a compiled APK and not an already-deployed cloud service. It has **not been tested end-to-end on your phone**. LBPH recognition is not spoof resistant. Green camera border only means a successful API recognition; it is not identity-proof. An unsuccessful scan displays an error message; not all errors show a red frame yet.

## 1. Run Python backend on Windows (PowerShell)
```powershell
cd backend
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
$env:AJ_ADMIN_USER = 'admin'
$env:AJ_ADMIN_PASSWORD = 'replace-this-with-a-unique-long-password'
python -m uvicorn app:app --host 0.0.0.0 --port 8000
```
Check http://127.0.0.1:8000/api/health in laptop browser.

## 2. Generate Flutter Android files and run
```powershell
cd android_app
flutter create --platforms=android --project-name aj_face_attendance .
flutter pub get
flutter doctor
flutter devices
flutter run
```
Add CAMERA and INTERNET permissions to `android/app/src/main/AndroidManifest.xml` as shown in `android_setup/AndroidManifest_permissions.xml.txt`. For LAN HTTP testing only, allow cleartext traffic. Use HTTPS for real deployment.

In Android app Settings enter your **PC LAN IP** such as `http://192.168.1.5:8000`, admin username and password; phone and PC must be on same Wi-Fi. `127.0.0.1` on the phone is NOT your PC. Android emulator uses `http://10.0.2.2:8000`.

## 3. Test functionality
- Register a student using ID, name, team.
- Capture 5+ face samples, one face per image, then Train Face Model.
- Attendance tab: start camera, choose Check-In or Check-Out. Scans every 3 seconds.
- Refresh dashboard and reports. Do not rely on uncalibrated LBPH for real attendance.

## 4. Build APK
```powershell
flutter build apk --release
```
APK (if build succeeds): `android_app/build/app/outputs/flutter-apk/app-release.apk`.

## 5. Cloud deployment — NOT completed
To run without a PC, deploy backend on a persistent hosting service with HTTPS, secure persistent DB + private face-photo/model storage, per-user access control, consent and liveness/spoof protection. **Do not deploy the SQLite and face-image directories on an ephemeral Render Free instance and expect persistence.** Set `AJ_ADMIN_PASSWORD` privately in the host's environment, never commit it. Enter the deployed HTTPS URL in mobile Settings. The backend currently uses one admin Basic Auth account; do not treat it as production-grade multiuser security.

## Privacy
Never upload `backend/data/`, `backend/trainer/`, student faces, passwords or API keys to a public GitHub repository. Get informed consent for biometric data. The provided app uploads photos to the configured backend.
