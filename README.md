# MacConnect

MacConnect shows your Mac desktop on a Windows PC on the same Wi-Fi or Ethernet network. The Windows keyboard and mouse control the Mac. Use it when the MacBook screen is working poorly.

The Windows app starts when you sign in and waits for the Mac. The Mac app starts when you log in, finds the Windows PC, and reconnects if either machine sleeps, reboots, or drops off the network.

## Read this first: set up a backup way in

No app can promise it never fails, and if the Mac screen is dead you cannot fix it from the Mac. **Set up the backup below while the Mac screen still works.** It does not depend on MacConnect, so if MacConnect ever stops working you can still reach the Mac.

On the Mac, open **System Settings > General > Sharing** and turn on:

1. **Remote Login**. This lets you open a text session from Windows and restart MacConnect (or anything else).
2. **Screen Sharing**. Click the (i) button next to it, then turn on **"VNC viewers may control screen with password"** and set a password. This shows the Mac desktop, including the login screen, in any VNC viewer.

Then write down the Mac's network address (also under Sharing, in the Remote Login line, for example `you@192.168.1.30`). In your router settings, reserve that address for the Mac so it does not change.

From Windows you can then:

- **Restart MacConnect:** in PowerShell run
  `ssh YOUR_MAC_USER@192.168.1.30 "launchctl kickstart -k gui/$(id -u)/com.macconnect.agent"`
  (replace the name and address; type `$(id -u)` exactly as shown).
- **See and control the Mac** without MacConnect: install a free VNC viewer such as TightVNC or RealVNC Viewer, and connect to `192.168.1.30` with the password you set.

Test both once, now, while you can see the Mac.

## Before you start

Both computers have to be on the **same home network**. This does not work over the internet.

You need the Mac screen once, long enough to approve two permission prompts. After that, Windows can be the display.

Leave the MacBook lid **open**. Closing it puts the Mac to sleep, and the picture disappears. While Windows is connected, the Mac also stays awake.

## 1. Install the Windows viewer

On this Windows PC, open PowerShell in this folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1
```

The script needs the .NET 8 SDK. Approve the administrator prompt so Windows Firewall lets the Mac connect. The firewall rule works on any network type, but only accepts connections from your own network. A shortcut is added to your Startup folder, so the viewer opens whenever you sign in. The script prints this PC's address at the end.

The window says **Waiting for Mac…**. Press **Esc** when you want to use Windows itself. Right-click the tray icon to go full screen again, or to exit.

The first time the Mac connects, choose **Yes**. That Mac is remembered and connects by itself after that. To forget it, delete `%AppData%\MacConnect\allowed.json`.

While the viewer runs, Windows will not go to sleep. If the viewer crashes, it starts itself again.

Viewer log: `%LocalAppData%\MacConnect\viewer.log`

## 2. Install the Mac agent

When the Mac screen is readable, install Apple's command line tools if you have not already:

```bash
xcode-select --install
```

Then, from this project folder:

```bash
bash scripts/install-mac.sh
```

The script builds the agent and tests that it starts before it replaces anything. If the new version does not start, it puts the previous version back. macOS then opens the Screen Recording settings. Turn on **MacConnect Agent** there, and under **Privacy & Security > Accessibility**.

If you later run the script again, macOS may ask for those two permissions again because the program changed. Do this while the Mac screen works.

The agent keeps running after you log in. If it quits, macOS starts it again. If it ever stops making progress, it restarts itself.

Agent log: `~/Library/Logs/MacConnect/agent.log`
Restart it: `bash scripts/restart-mac-agent.sh`

## 3. Log in automatically

The Mac app can start only after your user is logged in. It cannot show the disk-password screen.

1. Open **System Settings > Users & Groups**, then choose **Automatically log in as** and pick your user.

If FileVault is on, macOS will not log in automatically after a full shutdown or restart, and the disk password has to be typed on the Mac. Sleep and wake do not need it. If you can only use the Windows display, turn FileVault off, or expect to need a working Mac screen after every restart.

## 4. Check that it reconnects

1. Leave both apps running and the MacBook lid open.
2. Restart the Mac and log in.
3. The Windows PC should show the Mac desktop without you clicking anything.
4. Move the mouse on that window. The pointer on the Mac should follow.

## If the Mac cannot find the Windows PC

The Mac finds this PC by listening for a message it broadcasts once a second. Some routers block that on Wi-Fi ("client isolation", "AP isolation", or some guest and mesh networks).

The agent has two fallbacks:

- It remembers the last Windows PC it found and tries that address when it hears nothing.
- You can type the address in yourself (recommended if discovery ever fails). On the Windows PC, the address is shown on the "Waiting for Mac" screen, and in the tray menu under **Show this PC's address** (which also copies it). Then on the Mac run:

```bash
bash scripts/set-windows-ip.sh 192.168.1.20
```

The agent restarts and tries that address first, straight away, every time it starts. Automatic discovery still works as well. Reserve a fixed address for the Windows PC in your router so it does not change.

```bash
bash scripts/set-windows-ip.sh --show    # see what is set
bash scripts/set-windows-ip.sh --clear   # go back to automatic discovery only
```

The address is stored in `~/Library/Application Support/MacConnect/config.json` as `{ "windowsHost": "192.168.1.20" }`, so you can also edit it by hand.

## Keyboard

Keys are mapped for a US keyboard. Letters, numbers, arrows, function keys, and the common punctuation keys are sent to the Mac. So that shortcuts feel normal, **Ctrl acts as Command** (Ctrl+C copies, Ctrl+V pastes), **Alt acts as Option**, and the Windows key acts as Control. Double-click and right-click work. If the window loses focus, any held key is released on the Mac so nothing gets stuck.

## Speed

The Mac always sends its newest picture and drops older ones, so the picture does not fall behind. The picture is sent sharp (up to 2560 pixels wide, high JPEG quality). Quality goes down a little on its own, never far, if the network is slow, and back up when it is fast. The Mac's pointer is not drawn in the picture. The Mac sends its pointer position separately, about 120 times a second, and the viewer draws it on top, so you see the Mac pointer (also when you move it with the Mac's own trackpad) without waiting for a new picture. It is drawn as a plain arrow, whatever shape the Mac pointer has. The Windows pointer is hidden over the picture once the Mac pointer starts arriving. The Mac also compresses the next picture while it sends the previous one. Wired Ethernet on the Windows PC, or 5 GHz Wi-Fi on both, gives the smoothest result.

## Things that can still go wrong

- **Permission prompts.** macOS 15 and later asks now and then whether an app may keep recording the screen. That prompt appears on the Mac screen, which you may not be able to see. If MacConnect stops showing the Mac after a system update, use the backup above to reach the Mac.
- **Lid closed.** A MacBook with the lid closed and no external monitor goes to sleep no matter what the agent does.
- **Different networks.** Both computers must be on the same network.
- **Anyone on your network.** The Mac shows its screen to whichever Windows viewer answers on your home network. Do not use this on a network you do not trust.
- **Not tested on a Mac here.** The Windows viewer and its connection handling are tested automatically. The Mac agent was written without access to a Mac, so run the steps above while you can still see the Mac screen, and check that it works before you rely on it.

## Checks and tests

- Windows: `dotnet run --project windows/MacConnectViewer.Tests` acts as a fake Mac and tests the connection rules (handshake, reconnecting over a stale connection, dead connections, denied Macs, bad data).
- Mac: `.github/workflows/mac-build.yml` builds the agent on a Mac in GitHub Actions if you push this folder to GitHub, so a build error shows up without needing the MacBook.

## Ports

The Windows PC listens on TCP port **47900** and broadcasts a message on UDP port **47901** once a second. The installer adds a firewall rule for TCP 47900 only. The Mac connects to the Windows PC; you do not open ports on the Mac.
