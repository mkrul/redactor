# Redactor

Redactor is a menu-bar app for macOS. It removes a matched secret from the clipboard and leaves the rest of the copied text in place. The replacement is `[redacted]`. A short password copied by itself stays, unless that password matches a known secret shape.

The menu-bar icon means it is running. Nothing has to be closed, because there is no window.

## Install from this repository

```sh
make install
make package
make uninstall
```

`make install` builds Redactor, copies it to `~/Applications/Redactor.app`, and opens it. It does not ask for an administrator password. `make package` writes `dist/Redactor-macOS.zip`. `make uninstall` removes the login job and the app. It leaves `~/Library/Application Support/Redactor/` in place.

The app starts at the next login. Turn off Open at Login before you move the app to the Trash.

## Open the zip

Move `Redactor.app` into `~/Applications`. The app is ad-hoc signed and not notarized. On macOS 14 or earlier, right-click the app and choose Open the first time. On macOS 15 or later, try to open it, then choose System Settings > Privacy & Security > Open Anyway.

## Commands

```sh
redactor check
redactor status
redactor pause
redactor resume
```

`redactor check` reads UTF-8 text on stdin and writes the redacted text to stdout. Rule names go to stderr. It does not need the menu-bar app to be running.

`redactor status` prints `state: not running` and exits 1 when the app is not running. When the app is running, it prints a status block and exits 0. `pause` and `resume` change that state and then print the same block.

## Pattern list

The running app reads:

```text
~/Library/Application Support/Redactor/patterns.json
```

The `patterns.json` in this repository is the factory list. The app copies it into Application Support when that file is missing, and does not overwrite an existing file. The list matches a password, a key, a token, or a secret. A longer name is matched when it ends in one of those words, such as `API_KEY` or `APP_KEY`. A username or an email address is not matched. Edit the Application Support copy to add a company-specific name. Do not put a real secret in either file.

## Clipboard history

A clipboard-history app can keep a secret after Redactor removes it from the clipboard. Redactor removes that secret again only when the history app puts it back on the clipboard. Redactor does not delete history databases.
