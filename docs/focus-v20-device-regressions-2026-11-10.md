# Focus v20 Device Regressions

Status: first native CI failed; follow-up fixes pass local checks and await native rerun. Device acceptance and a new IPA remain pending.
Base commit: `dcab80e46dd498a42d023aa795caff2f4d326dc5`.

## Requirements

1. Default backup selection exports a verified file without rejecting native host data.
2. Toolbar download page opens after the preference panel has fully closed; one completed edge swipe returns without remnants.
3. Settings download/site-rule pages open without exposing underlying text at the top.

## Backup Evidence

Read-only shell Mach-O metadata and Capstone observations, not REA Evidence or runtime execution:

- Input: `<workspace>\_focus_ipa\Payload\PPBrowser.app\PPBrowser`
- SHA256: `6af11eb309cc7f2d75bd87ddaf4f6fb231305825a876678ae1414e2b7fcf424c`
- At `0x100244010` through `0x10024402c`, the host inserts `root`, an empty parent,
  and the localized bookmark title using only `bookmarkId,parentId,title`. URL,
  file type, and order remain SQLite NULL. The previous export assigned type 0
  and validation rejected it as a leaf without a URL.
- `CustomTagModel +bookMark` at `0x100053c28` sets type 1, order 1 and empty
  target/icon URLs. The previous shortcut validator required every entry to have
  a URL.
- Font picker logic at `0x10026772c` defaults to index 3; decrement at
  `0x100267fe0` stops at 0 and increment at `0x100268048` stops at 9.
  `0x100267998` through `0x1002679ac` writes the index into the live
  `PreferenceModel.fontSize`. The previous preference validator required 8-72.
- `FMResultSet -resultDictionary` at `0x100022168` retains original column names.
  Unlike its column lookup map, this method does not lowercase returned keys.
  No key-normalization workaround was added.

Implementation:

- Exclude the host-owned bookmark root from portable items, preserve it during
  replacement and portable snapshot restoration, and refuse incoming ownership
  of that ID. Exact device-local SQL recovery snapshots still include every row.
- Preserve the native type-1 bookmark shortcut. Other empty URL shortcuts and
  shortcut hierarchies remain invalid.
- Validate font indices in 0-9; reject booleans, fractions and out-of-range values.
- Export failures identify the category and read/validation stage. Host exception
  reasons are not displayed, and no partial backup is shared.

## Navigation Evidence

Read-only shell Mach-O metadata and Capstone observations of the same input
listed above, not REA Evidence or runtime execution:

- `BrowserViewController -hideUserPreferenceView` at `0x1000e47f4` starts
  preference-panel hiding and popup dismissal without waiting for completion.
- `PreferenceView -hide` at `0x100118ac8` starts a 0.25-second animation;
  its completion at `0x100118c0c` removes the view. Starting a page push
  immediately after hide therefore overlaps two transitions.
- The host panel and popup are `PreferenceView` and
  `PreferencePopUpController`, obtained from `preferenceView` and
  `popUpPreferenceController`.
- The previous downloads `viewWillDisappear:` restored navigation-bar
  visibility before an interactive pop had completed or been cancelled.

Implementation:

- Toolbar actions wait for both actual panel removal and popup dismissal
  completion, then navigate on the next main turn. Original cleanup callbacks
  are preserved; repeated taps are deduplicated. There is no fixed timeout that
  assumes cleanup succeeded.
- Owned pages prepare nonextended geometry and opaque navigation-item
  appearances before native push. Appearance setters run only once per page.
  The shared navigation surface is opaque and clipped while these pages are
  shown.
- Original host will-show/did-show callbacks remain in place. Surface restoration
  follows the final shown controller; a cancelled pop reapplies the state of
  the actual top controller. Nested owned forms and pushed descendants retain
  the owned surface until the final return to a host page.
- Navigation and edge-swipe gesture delegates are not replaced. Pending
  toolbar actions do not retain the browser. An abnormal host cleanup that
  never finishes blocks its action rather than pretending the menu is closed.

## Verification

- Initial Python source guards and full packaging/provenance regression: 74 tests passed.
  The CI-error follow-up passes 76 local tests, including callback-error
  writeback separation and asynchronous main-queue fixture guards.
  Initial full run failed at temporary-directory creation with Windows sandbox
  `WinError 5`; the authorized unsandboxed retry passed.
- `git diff --check`: passed after backup and navigation edits.
- Added executable native SQLite/defaults cases for each default category and
  combined export, root preservation on replace/restore, native shortcut
  preservation, strict font boundaries and bounded export diagnostics.
- Added UIKit callback fixtures for both panel/popup completion orders, repeated
  taps, original callbacks, released hosts, nested pages, completed return and
  cancelled return. These are wired into the simulator runner; their push spy
  records an animated request but suppresses real animation.
- CI42837951395 ran the new native tests for source
  `a110b46b9f8863ef5bf0ee89039b486f5576aa4c`. The default host export/restore
  shapes passed, but export diagnostics failed. UIKit failed at the first
  completed panel cleanup action; later navigation assertions were not reached.
  Foundation, WebKit and arm64 compilation passed.
- The workflow's `continue-on-error` gives those two steps a success conclusion
  while preserving their failure outcome. The aggregate gate correctly failed;
  compiled provenance and artifact upload were skipped.
- Actual device export, transition pixel/edge-swipe inspection and
  responsiveness remain required. Python source guards and callback fixtures
  do not prove that the device regressions are resolved.
- The production restoration hooks target the verified host
  `BaseNavigationController`; arbitrary plain navigation controllers are not
  claimed to have the same host-restoration coverage.
- No complete successful native verification, provenance artifact or new IPA
  has been produced for this repair yet.

## CI-Error Follow-Up

- Keep the export callback's `__block NSError` separate from the
  `NSError **` passed to the exclusive-access method. ARC's call writeback
  otherwise overwrites the callback error with the initial nil temporary.
  Native diagnostic cases now cover both non-SQL and actual SQL access.
- The UIKit fixture previously entered a nested run loop inside a main-queue
  block, then expected another main-queue block to have run. It now schedules
  assertion phases across actual main-queue turns and reports asynchronous
  exceptions through the fixture result callback. Production's next-turn
  navigation action is unchanged.
- Keep every original positive and negative assertion and the native publication
  gate. The follow-up still needs a successful macOS CI run before packaging.
