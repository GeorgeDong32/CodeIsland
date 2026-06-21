# Spec — User Experience Delta

## MODIFIED Requirements

### Requirement: Sessions Settings Section Exposes Cleanup Thresholds

The `sessions` Section in `SettingsView` SHALL provide Picker controls for all session-cleanup-related thresholds. The existing `sessionTimeout` Picker (whole-session idle eviction) SHALL be joined by three new Picker entries for sub-second-grained thresholds: subagent fast cleanup, transcript staleness with tool, and transcript staleness without tool. Each new Picker SHALL support a `0 = Never` option to disable the corresponding behavior, matching the existing `sessionTimeout` 0-doesn't-clean pattern.

#### Scenario: User sees the "Subagent Cleanup" Picker

- **GIVEN** the user opens the Settings view
- **WHEN** they scroll to the `sessions` section
- **THEN** they MUST see a Picker labeled "Subagent Cleanup" (localized key `subagent_cleanup`)
- **AND** a description line below explaining when to adjust it (localized key `subagent_cleanup_desc`)
- **AND** the Picker MUST offer the options: `Never` (tag 0), `15 Seconds`, `30 Seconds`, `60 Seconds`, `120 Seconds`
- **AND** the Picker MUST be initialized to the current value of `SettingsKey.subagentCleanupSeconds`

#### Scenario: User sees the "Transcript Stale (no tool)" Picker

- **WHEN** the user opens the `sessions` Settings section
- **THEN** they MUST see a Picker labeled "Transcript Stale (no tool)" (localized key `transcript_stale_no_tool`)
- **AND** a description line below (localized key `transcript_stale_no_tool_desc`)
- **AND** the Picker MUST offer the options: `Never` (tag 0), `30 Seconds`, `60 Seconds`, `120 Seconds`, `300 Seconds`
- **AND** the Picker MUST be initialized to the current value of `SettingsKey.transcriptStaleNoToolSeconds`

#### Scenario: User sees the "Transcript Stale (with tool)" Picker

- **WHEN** the user opens the `sessions` Settings section
- **THEN** they MUST see a Picker labeled "Transcript Stale (with tool)" (localized key `transcript_stale_with_tool`)
- **AND** a description line below (localized key `transcript_stale_with_tool_desc`)
- **AND** the Picker MUST offer the options: `Never` (tag 0), `60 Seconds`, `90 Seconds`, `120 Seconds`, `300 Seconds`
- **AND** the Picker MUST be initialized to the current value of `SettingsKey.transcriptStaleWithToolSeconds`

#### Scenario: New Pickers live in the existing `sessions` section, not a new section

- **WHEN** the user inspects the Settings sidebar / scroll
- **THEN** all three new Pickers SHALL appear within the existing `l10n["sessions"]` `Section` block
- **AND** they SHALL be positioned after the existing `sessionTimeout` Picker
- **AND** they SHALL appear before the `rotationInterval` Picker (the first unrelated Picker in the section)
- **AND** a new top-level section SHALL NOT be introduced (the related controls stay grouped)

#### Scenario: User changes "Subagent Cleanup" to 15 seconds

- **GIVEN** the Picker is currently at `30 Seconds`
- **WHEN** the user selects `15 Seconds`
- **THEN** `SettingsKey.subagentCleanupSeconds` SHALL be set to `15` in `UserDefaults`
- **AND** the subagent fast cleanup phase (phase 6) in `cleanupIdleSessions` SHALL use `15` as the staleness threshold on subsequent invocations
- **AND** idle subagent entries SHALL be removed after 15 seconds of idle time (faster than the previous 30s default)

#### Scenario: User sets "Transcript Stale (no tool)" to `Never`

- **WHEN** the user selects the `Never` option in the "Transcript Stale (no tool)" Picker
- **THEN** `SettingsKey.transcriptStaleNoToolSeconds` SHALL be set to `0` in `UserDefaults`
- **AND** the transcript staleness phase (phase 7) for sessions in `.processing` state SHALL be a no-op
- **AND** the user explicitly accepts that the Claude Code interrupt fallback is disabled for sessions in `.processing` (sessions may stay in "thinking" until a `Stop` event arrives, even after a long pause)

#### Scenario: User sets "Transcript Stale (with tool)" to `Never`

- **WHEN** the user selects the `Never` option in the "Transcript Stale (with tool)" Picker
- **THEN** `SettingsKey.transcriptStaleWithToolSeconds` SHALL be set to `0` in `UserDefaults`
- **AND** the transcript staleness phase (phase 7) for sessions in `.running` state SHALL be a no-op
- **AND** the user explicitly accepts that the Claude Code interrupt fallback is disabled for sessions in `.running`

#### Scenario: New settings survive an app restart

- **GIVEN** the user changed `subagentCleanupSeconds` to `60`, `transcriptStaleNoToolSeconds` to `120`, and `transcriptStaleWithToolSeconds` to `300` in Settings
- **AND** the user quits the app
- **WHEN** the user relaunches the app
- **THEN** the three Pickers MUST reflect the saved values (60, 120, 300) on the next open of Settings
- **AND** the values SHALL be persisted via `UserDefaults` (registered in `Settings.swift` `defaults.register` dict at app launch)

#### Scenario: Default values match the conservative defaults

- **GIVEN** the user has never opened Settings and never modified any of the three new keys
- **WHEN** the user opens Settings for the first time
- **THEN** the three new Pickers MUST show: Subagent Cleanup `30 Seconds`, Transcript Stale (no tool) `60 Seconds`, Transcript Stale (with tool) `90 Seconds`
- **AND** these defaults match the conservative values from the original plan (proven against typical Opus 4.6 / Sonnet 4.6 thinking times)

#### Scenario: New settings are exported in the diagnostics bundle

- **GIVEN** the user triggered a diagnostics export (e.g. via Help → Export Diagnostics)
- **WHEN** the diagnostics JSON is inspected
- **THEN** the `settings` object MUST include the keys `transcriptStaleNoToolSeconds`, `transcriptStaleWithToolSeconds`, and `subagentCleanupSeconds`
- **AND** the values MUST match the current `UserDefaults` values

### Requirement: New Localization Keys Exist in All Supported Locales

The new Picker labels and descriptions SHALL be present in all five supported locale dictionaries (English, Simplified Chinese, Japanese, Korean, Turkish). If a non-English locale does not have a native translation, the English string MUST still be present as a fallback (the `L10n` lookup already falls back to English for missing keys, but the key must be defined to avoid the `L10nTests` "key not found" assertion failing).

#### Scenario: New keys present in English dictionary

- **WHEN** the English (`en`) dictionary in `L10n.swift` is inspected
- **THEN** the following keys MUST be defined: `transcript_stale_no_tool`, `transcript_stale_no_tool_desc`, `transcript_stale_with_tool`, `transcript_stale_with_tool_desc`, `subagent_cleanup`, `subagent_cleanup_desc`
- **AND** the values MUST be natural English sentences / noun phrases

#### Scenario: New keys present in Simplified Chinese dictionary

- **WHEN** the Chinese (`zh`) dictionary in `L10n.swift` is inspected
- **THEN** the same 6 keys MUST be defined with natural Simplified Chinese translations

#### Scenario: New keys present in Japanese, Korean, Turkish dictionaries

- **WHEN** the Japanese (`ja`), Korean (`ko`), and Turkish (`tr`) dictionaries in `L10n.swift` are inspected
- **THEN** the same 6 keys MUST be defined
- **AND** the values MAY be English (acceptable fallback) or native translations

#### Scenario: `L10nTests` continues to pass

- **GIVEN** the `L10nTests` suite (asserts all keys referenced via `l10n[...]` exist in both en and zh)
- **WHEN** the new 6 keys are added to both `en` and `zh` dictionaries
- **THEN** the existing test suite SHALL pass with no modifications
- **AND** the test SHALL fail if any of the 6 keys is missing from either dictionary (regression guard for future maintainers)
