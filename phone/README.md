# MacConnect phone

Android app that shows your Mac desktop and controls it, over Wi-Fi or a USB cable.

The Mac agent has to be the version that listens for a phone. From the project root, on the Mac:

```bash
bash scripts/install-mac.sh
```

Then, from this folder:

```bash
flutter pub get
flutter run
```

Wi-Fi: the phone and the Mac have to be on the same network. The app lists the Mac, or you can type its address.

Cable: plug the phone into the Mac and open Cable in the app.

- USB tethering: Settings, Hotspot and tethering, USB tethering.
- USB debugging: Developer options and USB debugging. The Mac forwards the cable when `adb` is installed (`brew install android-platform-tools`). Then tap **Connect through USB debugging**.

Touch the picture to click. Drag to move. Two fingers scroll. A long press is a right click. The keyboard button types on the Mac.
