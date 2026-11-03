# UI conventions

This file records the decisions behind the two visual themes, so a later change
does not have to re-litigate them. It describes what the code already does.
Where a rule has a reason, the reason is here rather than in a commit message.

Matter draws the same widgets in two skins. `AppThemeStyle` selects new-skeuomorphic
(`NeuColors` shadows and depth) or Material (M3 `ColorScheme` fills). Business
logic, state and layout are shared; only the skin branches, through
`context.isMaterial`.

## Where a theme decision belongs

`lib/theme/neu_theme.dart` and `lib/theme/material_theme.dart` are the only
places that decide type, shape and colour. A page that calls `copyWith` on a
`titleTextStyle`, sets its own `shape`, or hard-codes a colour role is doing the
theme's job, and the result will drift from the other pages.

The Material theme configures typography, card, app bar, navigation bar, divider,
list tile, input, chip, segmented button, all four button families, FAB, switch,
progress, tab bar, dialog, bottom sheet, popup menu, snack bar and tooltip. If a
page needs something outside that list, add it there first.

## Type

`_buildTextTheme` in `material_theme.dart` gives every slot a size **and** a
weight. M3's `titleLarge` is 22 pt at w400, which reads as body text when it
titles a page, so the page-title token is 24/w600
(`materialPageTitleSize` / `materialPageTitleWeight`).

- Page titles use `headlineSmall`. `buildFloatingAppBar` gets it from
  `appBarTheme.titleTextStyle`, so call sites pass a bare `Text`.
- Self-drawn title rows (`CascadeTitle` in the chat, space and hidden-rooms
  pages) use `headlineSmall` too.
- Chinese line heights are tightened to 1.35–1.5. M3's 1.5 leaves list rows
  loose.
- Numeric slots use `FontFeature.tabularFigures()`, so counters, durations and
  speeds do not jitter as they update.

## Surfaces

Layering comes from fill lightness, not from borders or elevation. In dark mode a
step only ever goes **lighter**: a darker fill inside a lighter surface reads as a
hole, not as a layer.

| | page | card |
|---|---|---|
| light | `surfaceContainer` | `surfaceBright` |
| dark | `surface` | `surfaceContainer` |

The light page must **not** be `surface`. M3 puts `surface` and `surfaceBright`
both at tone 98 in light mode, so a page on `surface` and a card on
`surfaceBright` land at 1.02:1 and the card cannot be seen. `surfaceContainer`
gives 1.11:1, the same step the dark side has.

Presets that pull `surface` to pure black or pure white (`MaterialBackground`)
stop the M3 container roles from connecting to the page; `_surfacesOf` then
falls back to a luminance lift, so a card is still raised.

Cards carry `elevation: 0`. Shadows belong to what actually floats: the dock,
dialogs, menus, sheets.

## Lists

The shape depends on whether the rows are **categories** or a **stream**.

- **Categorised rows** (settings, forms): each category is one card, with the
  hairlines inside it. Categories are the unit the reader navigates by, so
  giving each one a boundary helps.
- **A stream of like items** (chats, contacts, search results): bare rows on the
  page with hairlines between them. Nothing is being grouped, so a card would
  impose a boundary the content does not have, and once the stream is long the
  block is just a slab.

Do not carry a shape from one to the other. A settings page groups because its
items categorise; a chat list is a stream even though it is also made of rows.

### Categorised rows

`GroupedRows` owns one filled `Material` with the theme's card outline around
the category. Hairlines paint on top of that same fill. The individual
`ListTile` shapes are square so their pressed ink reaches the row edges; only
the group's outside boundary clips it. Material cards and grouped settings use
28 dp circular corners from `material_theme.dart`, independent of the
new-skeuomorphic radius scale. Action buttons use a full pill; Material FABs use
56 × 56 dp icon-only controls with 16 dp circular corners.

Neither of the other two shapes works here. A card wrapped around the run draws
two boundaries, the card edge plus the hairline. Spaced-out cards turn the group
into a stack of pills, and the space costs a row of vertical room for nothing.

Rows must be wrapped in `Material`, not a `DecoratedBox`: `ListTile` paints its
background and ink splashes on the nearest `Material` ancestor, so a coloured
`DecoratedBox` above it hides them and the framework asserts.

The new-skeuomorphic branch keeps its own raised surface around the run, because
there the block is the structure and the rows are its contents. `GroupedRows`
handles both branches so call sites do not have to.

### Streams

`ChatListDivider` draws the hairline. It is the single switch, so no call site
needs a branch.

`ChatListDivider` draws the hairline, aligned with the stream's text. Material
chat and contact rows use a 44 dp avatar, 12 dp of horizontal row padding and a
12 dp content gap, so their divider starts at 68 dp; compact chat rows use a
40 dp avatar and a 64 dp inset. Vertical padding is 10 dp, or 8 dp for compact
chat rows. New-skeuomorphic rows keep their original dimensions.

Material conversation titles use 16 dp type with a medium weight, rising to
semibold for unread rooms. Previews stay on one line to preserve list density;
time and unread markers share a separate trailing column. Membership actions
sit below the complete row, so accepting or rejecting an invitation retains
enough width with enlarged text. Contact message actions use unfilled icon
buttons, leaving accent fills to primary and selected actions.

Settings `ListTile` titles follow a separate alignment contract:
`contentPadding.left + minLeadingWidth + horizontalTitleGap` is 16 + 24 + 8,
matching `NeuSpacing.rowTitleInset` (48 dp). Changing any of those three requires
checking the group's divider inset too.

### Tones

A screen shows two tones wherever a card sits on a page: the page tone, then the
card tone. A screen with only one visible tone means the card and page fills
collapsed, which is what happened when the light page was taken from `surface`
rather than `surfaceContainer`. Streams have no card, so such a screen shows one
tone plus hairlines, and that is correct for it.

## Row semantics

`_SettingItem.selects` separates the two meanings a row can have:

- `chevron_right` — this row goes somewhere.
- `unfold_more` — this row picks a value here (theme, and any future picker).

Drawing one arrow for both left the user unable to tell a page push from a
picker until after the tap.

## Search and primary actions

`AppSearchField` uses the native M3 `SearchBar` in Material and `NeuTextField` in
new-skeuomorphic pages. The search bar is a flat pill on the card surface; its
fill, shape and type come from `searchBarTheme`. Chat search remains a read-only
entry that opens the search route, while contacts filter in place.

On mobile, new chat and add space are icon-only FABs owned by the app's outer
Scaffold, so both clear the floating dock and snack bars. Standalone chat and
space pages own their own FAB; embedded desktop lists keep the toolbar action.
Material FABs omit visible labels and keep tooltips for discovery and screen
readers, including the selected-chat count when restoring hidden chats.

The settings profile card shares the neutral card fill with ordinary settings
groups. Its 52 dp avatar and 18 dp title keep the profile recognisable without
turning it into a coloured banner. Section headings use `onSurfaceVariant`;
primary colour marks selected values and primary actions. The Material theme
picker groups appearance families and uses light, dark and paired thumbnails
for the Material options.

## Dividers

`DividerThemeData` uses `onSurface` at 14%, never `outlineVariant`. The outline
role reads about twice as heavy on the dark page as on the light one, and it
carries the seed's tint.

## Glass

`GlassPanel` and the fade blurs are for layers that float **over** scrolling
content: the toolbar, a floating search field, chat overlays, sheet cards. A
large static panel uses `NeuSurface`; glass on it would drown the depth the
theme is built on, and cost readability.

Blur is decoration in the new-skeuomorphic theme and structure in Material. In
Material the toolbar must actually blur what scrolls under it, so the user's
"blur off" switch only drops the strip fallback; it does not turn the toolbar
into a flat colour.

`TopFadeBlur` uses different gradients per theme. The neu curve is down to 0.24
alpha by the halfway point, which put the toolbar title on a nearly transparent
layer with list rows showing through the text. The Material curve holds an
opaque band to 74% and fades only the last quarter.

The Material header and the dock deliberately use different alphas: the header
covers a title, the dock is a platter over content.

## Navigation

Material's dock is a floating capsule (`DockSurface`), inset 14 dp from each
side and 10 dp off the bottom, not a full-bleed bar.

The dock paints a translucent lens itself. Selection colour comes from the
icon and label pixels under that lens; the uncovered pixels keep their neutral
colour. Both passes paint the same glyph and share the lens background's rounded
rectangle, including its growth and jelly deformation. Magnification is painted
only inside the lens, without changing destination layout or semantics.

A press lifts the dock immediately, with platter growth capped at 16 logical
pixels so both end caps stay on screen. Holding and sliding moves the lens
continuously and switches the page as soon as the pointer crosses into another
destination, using the existing page transition. Releasing snaps the lens to the
current destination without dispatching the same selection again. There is no
long-press timeout. The dock owns one primary pointer across the whole bar, so
crossing item boundaries does not cancel the gesture and another finger cannot
take it over. Pointer cancellation keeps the last selected page; movement past
either horizontal edge clamps to the end destination. Item semantics retain
independent tap actions.

The held lens follows a spring that preserves velocity when retargeted. Its
actual speed drives horizontal stretch and vertical squash, and its jelly
relaxes when motion stops. Finger position never writes the shared page-position
notifier. The lens keeps its own motion until it and the selected page settle,
then returns to following page swipes. Destination layout, hit positions and the
lens use the same inset and pitch, mirrored together for right-to-left layouts.

## Motion and toolbar controls

`MaterialPress` wraps the complete filled control, including its background.
Its spring follows the control's `WidgetStatesController`, so touch, keyboard,
scroll cancellation and disabling all use the same press lifecycle. A quick tap
still rises before settling. Growth is capped by both a percentage and a pixel
budget so wide cards stay restrained. The render transform changes paint only:
layout, hit testing and popup anchors stay at rest. Reduced motion disables it.

`NeuAction`, `NeuButton`, `NeuIconButton` and space cards use that feedback in
Material. Their new-skeuomorphic branches keep their existing press treatment.
Toolbar icon controls use `MaterialToolbar` and a neutral filled pill, with the
style defined in `material_theme.dart`; inline buttons keep their usual fill.
Settings section headings use `titleSmall` rather than letter-spaced captions.

Material routes use Flutter's forward fade and horizontal slide on Android and
desktop; iOS keeps its native back gesture. `NeuColors` is also used as the
compatibility palette by shared widgets, so it interpolates every colour during
a theme transition instead of switching the whole palette halfway through.

## Desktop and tablet composers

Wide chat input uses one flat surface with a top divider, an unframed editor,
and rectangular controls. Do not nest glass, raised cards and a recessed
field around the same editor. Composer control shapes live in
`material_theme.dart` and are shared by both skins. The device-local interaction
setting offers automatic, touch and keyboard/mouse modes. Automatic uses
keyboard/mouse on Linux, Windows and macOS, and touch on Android and iOS.
Keyboard/mouse targets are 32 dp; touch targets remain 48 dp. The mode also
controls plain-message drag selection, not hardware keyboard shortcuts or
secondary-click actions, which remain available in every mode.

Pane widths alone control single/split layouts and the expanded editor
(600 dp or wider); changing interaction mode never forces a wide layout.
Tablets follow system rotation, while phones retain the portrait preference.

## Checking a change

Render the touched screen in both brightnesses at a phone width before and after.
A throwaway widget test does it: pump the page inside a `RepaintBoundary`, load
Roboto with `FontLoader` so text has glyphs, and write
`RenderRepaintBoundary.toImage` to a PNG outside the repository. Look for a card
that matches the surface it sits on, which means the page and card tones
collapsed, and for a tonal container fill surviving where only fill levels
should be.

Test-environment caveat: the bundled test fonts have no CJK coverage, so Chinese
labels render as boxes. Read structure and tone from those shots, not labels.
