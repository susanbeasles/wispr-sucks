# Plan: menu-bar control panel (clickable mic -> popover)

## Goal
Click the menu-bar mic -> a compact NSPopover control panel (not a deep
dashboard). Most-wanted control: live vocabulary add/remove (no CLI, no restart).

## Why a popover (not the current NSMenu)
NSMenu can't hold a text field, so vocabulary entry needs a real view. An
NSPopover anchored to the status-item button is the right "control panel"
affordance. Left-click toggles the popover.

## Key design win
StatusItemController gets the SAME DictionaryStore instance the Dictator uses
(passed from main). Adding a word updates the shared in-memory entries, and the
Dictator re-reads dictionary.terms() at the start of every session - so a word
added in the panel takes effect on the NEXT dictation with NO app restart. This
removes the friction noted in DECISIONS.md.

## Panel contents (top -> bottom)
- Title "SonarDictate" + state (Idle/Listening, live-updated via setListening).
- Stats line: "<n> recordings - <m> words - <r> indexed".
- Vocabulary: text field + Add button; scrollable list of current words, each
  with a Remove (x) button. Add -> dictionary.add(.manual); Remove ->
  dictionary.remove. Refresh the list in place.
- Cleanup toggle (checkbox) bound to Cleanup.isEnabled (same as the old menu item).
- Actions: Dictation History..., Show Storage in Finder, Reset Storage... (keeps
  the existing critical confirmation), Quit.

## Files
- NEW Sources/SonarDictate/ControlPanel.swift: ControlPanelController:
  NSViewController, builds the view programmatically (no nib), exposes refresh()
  and setState(listening:). Holds store/workflows/rag/dictionary + history ref +
  onReset closure (reset alert/quit stays in StatusItemController).
- StatusItemController: hold an NSPopover with ControlPanelController; button
  action toggles it (NSApp.activate so the text field can take focus); keep
  setIcon/setListening; forward refresh + listening into the panel; remove the
  always-on NSMenu (move its actions into the panel). Keep Reset alert here.
- main.swift: pass `dictionary` into StatusItemController(...).

## Constraints / risks
- LSUIElement app: popover from a status item works; call NSApp.activate(
  ignoringOtherApps:true) on open so the Add field is editable.
- Fixed panel width (~340). Vocab list in an NSScrollView with a vertical
  NSStackView document, doc width pinned to the clip view.
- Don't touch the audio/dictation path. Pure UI + existing store calls.
