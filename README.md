# MacConnect

MacConnect shows your Mac desktop on a Windows PC that is on the same Wi-Fi or Ethernet network. The Windows keyboard and mouse control the Mac. Use it when the MacBook screen is working poorly.

The Windows app starts when you sign in and waits for the Mac. The Mac app starts when you log in, finds the Windows PC, and connects again if either machine sleeps, reboots, or drops off the network.

## Before you start

Both computers have to be on the **same home network**. This does not work over the internet.

You need the Mac screen once, long enough to approve two permission prompts. After that, Windows can be the display.

Leave the MacBook lid **open**. Closing it puts the Mac to sleep, and the picture disappears. While Windows is connected, the Mac also stays awake.

## 1. Install the Windows viewer

On this Windows PC, open PowerShell and run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1
```

The script needs the .NET 8 SDK. Approve the administrator prompt so Windows Firewall allows the Mac to connect. A shortcut is added to your Startup folder, so the viewer opens whenever you sign in.

The window says **Waiting for Mac…**. Press **Esc** when you want to use Windows itself. Right-click the tray icon to go full screen again, or to exit.

The first time the Mac connects, choose **Yes**. That Mac is remembered and connects by itself after that. To forget it, delete `%AppData%\MacConnect\allowed.json`.

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

macOS will open the Screen Recording settings. Turn on **MacConnect Agent**. Also turn it on under **Privacy & Security > Accessibility**. If a switch was already off after you toggled it, turn it off and on again. Rebuilding the agent later can ask for these permissions again.

The agent keeps running after you log in. If it quits, macOS starts it again.

Agent log: `~/Library/Logs/MacConnect/agent.log`

## 3. Log in automatically

The Mac app can start only after your user is logged in. It cannot show the disk-password screen.

1. Open **System Settings > Users & Groups > Login Options**.
2. Turn on automatic login for your user.

If FileVault is on, macOS will not automatically log in after a full shutdown. Type the password on the Mac once after that kind of start. Later connections, including after sleep, do not need that step.

## 4. Check that it reconnects

1. Leave both apps running and the MacBook lid open.
2. Restart the Mac and log in.
3. The Windows PC should show the Mac desktop without you clicking anything.
4. Move the mouse on that window. The pointer on the Mac should follow.

Press **Esc** on Windows to shrink the window and use the Windows PC. Choose **Full screen** from the tray icon to use it as the display again.

## Keyboard

Keys are mapped for a US keyboard. Letters, numbers, arrows, modifiers, and the common punctuation keys are sent to the Mac. The Windows key acts as Command.

## Ports

The Windows PC listens on TCP port **47900**. It broadcasts a beacon on UDP port **47901**. The installer adds firewall rules for both. The Mac connects to the Windows PC; you do not open ports on the Mac.
