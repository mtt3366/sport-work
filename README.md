# SportWork

SportWork is a tiny macOS menu bar app that alternates:

- `27` minutes of focus
- `3` minutes of movement

While you are in the 27-minute focus block, it can also send a small "5-second reset" reminder every 3 minutes. That reminder can be enabled or disabled from the menu bar.

## Features

- Runs as a menu bar app with no dock icon
- Shows a walking-person icon in the macOS menu bar
- Starts counting immediately when launched
- Lets you choose the reminder mode for 27-minute transitions:
  - menu bar flash
  - system notification
- Lets you choose the reminder mode for 3-minute micro reminders:
  - menu bar flash
  - system notification
- Runs a 3-minute move countdown
- Automatically returns to the next 27-minute focus session
- Optional 3-minute micro reminders during focus
- Lets you change focus length and move length from the menu
- Can be set to launch automatically at login
- Pause, resume, reset, and trigger move mode manually

## Build

```bash
./build.sh
```

Artifacts:

- App bundle: `build/SportWork.app`
- Disk image: `build/SportWork.dmg`

## Install

1. Open `build/SportWork.dmg`
2. Drag `SportWork.app` into `/Applications`
3. Open the app
4. If macOS warns that it is from an unidentified developer:
   - go to `System Settings -> Privacy & Security`
   - click `Open Anyway`
5. If you choose any system notification mode, allow notifications the first time the app asks

## Use

After launch, look at the top-right of the macOS menu bar for the walking-person icon and countdown text.

Menu actions:

- `Pause` / `Resume`
- `Disable 3-minute reset reminders` or enable them again
- `Enable launch at login` so the app starts when you log in
- `Set focus minutes...`
- `Set move minutes...`
- `27-minute reminder mode`
- `3-minute reminder mode`
- `Start 3-minute move now`
- `Reset cycle`

When reminder mode is set to `Flash in menu bar`, the menu bar text blinks briefly instead of sending a system notification.

## Update

When you change the code later:

```bash
./build.sh
```

Then replace the old installed app with the new one:

1. Quit `SportWork` from the menu bar
2. Delete `/Applications/SportWork.app`
3. Copy the newly built `build/SportWork.app` into `/Applications`
4. Open it again

If `launch at login` was enabled, the setting will continue to work after you replace the app in `/Applications`.

## Uninstall

1. Quit `SportWork` from the menu bar
2. If launch at login is enabled, open the app once and click `Disable launch at login`
3. Delete `/Applications/SportWork.app`
4. Optionally remove saved state:

```bash
rm -rf ~/Library/Application\\ Support/SportWork
rm -f ~/Library/LaunchAgents/com.lucas.sportwork.launcher.plist
```

## Rebuild after changes

```bash
./build.sh
```

The script rebuilds the release executable, recreates the `.app`, and recreates the `.dmg`.
