# Localization

The interface follows the system language on a fresh install. Existing explicit Chinese / English choices are retained. Open the header gear or **LumaLab → 设置…** (`⌘,`) to select **简体中文**, **English**, or **跟随系统**. The selection applies immediately to the main window and menus. Existing photo edits and unsaved changes remain in `EditorModel`; changing language rebuilds only the view tree. UI-only state such as an expanded section or a selected curve channel can return to its default.

The preference is machine-local (`LumaLab.interfaceLanguage` in UserDefaults). It is not serialized into a photo Sidecar, a portable project, a DNG XMP payload, or the shared edit model. Follow System uses Chinese when the first preferred language begins with `zh`; otherwise it falls back to English. Native file dialogs and standard macOS menu items continue to use the operating system's language.

## Shared catalog and macOS adapter

- `Resources/localization-en.json` is the platform-neutral UTF-8 catalog. Chinese strings are stable keys; English is the translated value. A future Windows UI can load the same JSON without Foundation, AppKit or SwiftUI.
- `scripts/generate-localization.py` creates `LocalizationCatalog.swift`, checked into source so an installed app needs no external resource lookup or network access.
- `Localization.swift` contains the macOS preference, translation adapter, Settings view and independent checks.
- `scripts/localize-ui.py` adapts display boundaries in **Sources/LumaLab only**. Domain data and persistence identifiers are unchanged. Run it after adding UI, then inspect the resulting changes. `--check` reports pending unadapted calls.

Translation first checks the full string. Interpolated labels use anchored templates with numbered placeholders (`{0}`, `{1}`). There is no substring replacement in arbitrary filenames or user text. User-entered names and source filenames should be rendered verbatim. Edit names stored by an older version stay as originally stored. Default automatic mask names (including per-face numbers) receive a display translation; custom mask names remain verbatim. Neither path changes the stored name.

The application-owned menus, inspector controls, sheets, help labels, status messages, error alerts and metadata labels are translated. Camera-provided metadata values, filenames, user names and operating-system-provided error details are preserved. An unknown string falls back to Chinese rather than disappearing. New features must add their interface strings to the JSON catalog.

## Validation

`LumaLab --localization-check` checks static labels, Chinese passthrough, interpolated counts and enum titles, filename preservation, system-language fallback, and matching placeholder sets for every entry. These checks are also part of `--self-test` and do not require a GPU.

After changing the JSON, regenerate the Swift file and run the check. A full build plus GUI validation remains part of release verification.
