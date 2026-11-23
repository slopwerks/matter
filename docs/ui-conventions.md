# UI conventions

This file records the decisions behind the two visual themes, so a later change
does not have to re-litigate them. It describes what the code already does.
Where a rule has a reason, the reason is here rather than in a commit message.

Matter draws the same widgets in two skins. `AppThemeStyle` selects new-skeuomorphic
(`NeuColors` shadows and depth) or Material (M3 `ColorScheme` fills). Business
logic and state are shared. Material uses its own adaptive shell; Neu keeps its
mobile navigation and draggable desktop columns. Presentation components branch
through `context.isMaterial`; new value-only styling consumes `context.tokens`.
The M0 foundation is `AppDesignTokens` in `lib/theme/tokens/`, mounted by both
builders. It supplies spacing, radii, surfaces, title styles and motion parameters;
consumer migration is separate work. Missing tokens are a theme setup error, not
a reason to silently fall back to another skin.

## Where a theme decision belongs

`lib/theme/neu_theme.dart` and `lib/theme/material_theme.dart` are the only
places that decide type, shape and colour, together with Material palette
roles in `material_color_scheme.dart`. `material_chat_styles.dart` is a part of
the Material theme library and owns its chat, picker and media presentation.
A page that calls `copyWith` on a
`titleTextStyle`, sets its own `shape`, or hard-codes a colour role is doing the
theme's job, and the result will drift from the other pages.

The Material theme configures typography, card, app bar, navigation bar, divider,
list tile, input, chip, segmented button, all four button families, FAB, switch,
progress, tab bar, dialog, bottom sheet, popup menu, snack bar and tooltip. If a
page needs something outside that list, add it there first.

### Shared component presentation

`AppComponentTheme`, mounted by both theme builders, supplies conversation-row
radius, padding, avatar sizes, layout policy and floating-toolbar button style.
`ChatListItem` consumes that contract rather than checking the skin; its two
presentation widgets retain their original inline-status / trailing-status
layouts. Drafts, unread overrides, membership actions and navigation remain in
the stateful host. `GroupedRows` reads card/hairline/spacing from `context.tokens`.
`MaterialToolbar` applies the optional theme-provided style and is transparent
to its child when no override is present. Geometry interpolates and discrete
layout policies switch at the compatibility palette's midpoint.

## Type

`_buildTextTheme` in `material_theme.dart` gives every slot a size **and** a
weight. M3's `titleLarge` is 22 pt at w400, which reads as body text when it
titles a page, so the page-title token is 24/w600
(`materialPageTitleSize` / `materialPageTitleWeight`).

- Page titles use `headlineSmall`. `buildFloatingAppBar` gets it from
  `appBarTheme.titleTextStyle`, so call sites pass a bare `Text`.
- Self-drawn title rows (`CascadeTitle` in the chat, space and hidden-rooms
  pages) use `headlineSmall` too.
- Material root pages use `MaterialRootHeader`: compact headers use
  `headlineLarge` at 34/w700 with a 42 dp line height. Wide list panes use
  an 84 dp toolbar and a 28/w700 title. Subpage app bars use 24/w600.
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
| light | `surface` | `surfaceContainerLow` |
| dark | `surface` | `surfaceContainerLow` |

The default purple tonal palette follows the HTML prototype's explicit roles
in `material_color_scheme.dart`. Other seed colours and scheme variants remain
generated; system colours and the existing background presets remain selectable.
`_surfacesOf` maps roles directly, without adjusting the page to enforce an
artificial page/card contrast threshold. Background presets update neutral
surfaces without replacing accent roles.

Cards carry `elevation: 0`. Shadows belong to what actually floats: the dock,
dialogs, menus, sheets.

## Message bubble surfaces

`TimelineBubbleFrame` owns the text container and joined-corner geometry.
Outgoing and incoming fills use `tokens.surfaces.bubbleOutgoing` and
`bubbleIncoming`: Material maps them to `primaryContainer` and
`surfaceContainerHigh`, with outgoing text on `onPrimaryContainer`;
Neu maps them to accent and its dense `NeuColors.card`, not the base card token.
Neu keeps its existing gradient/shadow switches. Outer and tail corners consume
`tokens.radii.bubble` / `tag`: Material uses 20 dp outer and 4 dp joined corners;
Neu keeps 18 dp outer and 6 dp joined corners. The legacy helper exports
remain available from `message_group.dart` for compatibility.

Material centres the reading region and caps it at 720 dp, with its own
MediaQuery width for media sizing. Text bubbles use 75% of that width, capped
at 540 dp, with 14 × 10 dp padding and a 16/26 body line height. Neu retains
68% of the viewport capped at 520 dp.
The text-bubble key stays on the actual container; menu, gesture and send-flight
wrappers stay outside. Media bubbles share shape/shadow helpers without gaining
an extra text container or changing their own sizing and transparent surfaces.

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
the category. Hairlines paint on top of that same fill. Individual rows use a
stadium for hover, focus, press and selection, as do filter chips.
Material cards and grouped settings use
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
40 dp avatar and a 64 dp inset. Material chat rows use 14 dp vertical padding,
36 dp corners and `secondaryContainer` selection, producing a 72 dp default
row. Dense rows retain 8 dp padding. Contact rows keep their own dimensions.
New-skeuomorphic rows retain their original geometry and accent-soft selection.

Room-management members and join requests follow the same bare-stream rule,
with 44 dp avatars and 12 dp content gaps. Their lazy rows keep long rooms
scrollable; request reasons wrap above the approval and rejection buttons.
Space member previews use the same identity rows, including Matrix IDs.
Conversation detail panes and their modal view use those same bare member rows,
without truncating names or Matrix IDs.
Ignored-user sheets wrap the full ID and place the unignore action below it.
The Material space index uses compact two-line rows with a 44 dp rounded-square
avatar. The first line pairs the name with an optional unread badge. The second
shows the visible direct room count and space topic.
Inside a space, the room directory retains the prototype's card grid. Each card owns its
ink and press feedback, with a 44 dp avatar and the shared list title style.

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

Neutral categories sit on `surfaceContainerLow`; selected rows use
`secondaryContainer`. The compact root header and profile card use
`primaryContainer` with `onPrimaryContainer`. Space avatar fallbacks use primary,
secondary, tertiary and high-surface container roles keyed by space ID. Streams stay on the page
surface without an enclosing card.

## Row semantics

`_SettingItem.selects` separates the two meanings a row can have:

- `chevron_right` — this row goes somewhere.
- `unfold_more` — this row picks a value here (for example, the startup page on mobile).

Drawing one arrow for both left the user unable to tell a page push from a
picker until after the tap.

## Search and primary actions

`AppSearchField` uses the native M3 `SearchBar` in Material and `NeuTextField` in
new-skeuomorphic pages. The search bar is a flat pill; its
fill, shape and type come from `searchBarTheme`. Chat search remains a read-only
entry that opens the search route, while contacts filter in place. Material
keeps search in the fixed root header, using `surface` inside the compact tonal
header and `surfaceContainerHigh` inside plain pane headers. Neu preserves
its scrolling search and replacement header button.

On mobile, new chat and add space are icon-only FABs owned by the app's outer
Scaffold, so both clear the floating dock and snack bars. Standalone chat and
space pages own their own FAB; embedded desktop lists keep the toolbar action.
Material FABs omit visible labels and keep tooltips for discovery and screen
readers, including the selected-chat count when restoring hidden chats.

The settings profile card uses `primaryContainer` / `onPrimaryContainer`,
18 dp padding, a 52 dp avatar and an 18 dp title. Section headings use
`onSurfaceVariant`; primary colour marks selected values and primary actions.
The theme row summarizes the current family and brightness. Its detail page
shows the two choices separately and applies them together. Wide Material
layouts show the page beside the settings list.

## Dividers

`DividerThemeData` uses `onSurface` at 14%, never `outlineVariant`. The outline
role reads about twice as heavy on the dark page as on the light one, and it
carries the seed's tint.

## Glass

`GlassPanel` and the fade blurs are for layers that float **over** scrolling
content: the toolbar, a floating search field, chat overlays, sheet cards. A
large static panel uses `NeuSurface`; glass on it would drown the depth the
theme is built on, and cost readability.

Material root headers, subpage app bars and the navigation rail use opaque
semantic surfaces. The compact dock retains its blurred floating platter. Neu retains its fade
blur headers and floating overlays; the blur settings still apply there and to
shared overlays that explicitly use glass.

## Navigation

Material uses four destinations: chats, spaces, contacts and settings.
Below 600 dp, the 62 dp lens dock sits in a capsule, inset 16 dp horizontally
and 12 dp plus the bottom safe area. Pressing lifts the platter and magnifies
the lens; sliding carries its spring and jelly deformation across destinations.
In the compact layout, page swipes drive the same continuous position. Wider
layouts use the side rail to switch destinations. The dock hides while a single-pane
chat or a secondary detail is open. The rail defaults to 80 dp from 600 dp and 256 dp from 1200 dp.
The toggle animates its width and fades between layouts. Dragging follows the
pointer directly. Double-clicking the divider restores the responsive default. The
device remembers the preferred width and limits it to fit the window.
Its four labelled destinations share a moving indicator with the page
transition. The chat list offers space shortcuts by name in its filter row.

From 840 dp the conversation list opens beside the chat at a default width of
320 dp. Its divider remembers the user's width separately from the navigation
rail. Double-clicking resets it to 320 dp. At 1600 dp, room details default to a
persistent 360 dp supporting pane. Below that, details overlay the chat as an
end panel or, below 840 dp, a bottom panel. A modal panel can be dismissed by
its close button, barrier, Escape or back. The modal takes focus from the
underlying list and chat; the persistent pane does not.

`MaterialAdaptiveShell` keeps the same `MobileTabView` tree at every width.
`MaterialConversationLayout` retains the list and selected chat using stable
keys and Offstage rather than replacing routes. The chat receives a MediaQuery
for its actual pane. Selection, list position, focus and drafts survive resizing;
account switches intentionally replace the page tree. Single-pane chats disable
page swipes so message gestures cannot accidentally change the destination.
Conversation tools such as room discovery, pinned messages and room management
open in the chat detail pane. Back first closes the current tool. Selecting a
room from the conversation list returns the pane to its timeline.
Neu keeps the existing 960 dp desktop breakpoint and draggable split widths.
The M3 shell reuses the existing lens dock and its motion rather than replacing
it with native bottom-navigation transitions.

Settings, spaces and contacts use `MaterialListDetail`: one retained list and
one nested route stack per destination. Below 840 dp a selected detail fills
the content pane; at 840 dp the list stays beside it (320 dp, or 360 dp from
1200 dp). Back closes only the active destination's detail. Switching tabs and
resizing keep forms and routes alive; switching accounts resets them.
The empty selection belongs only to the split pane. On narrower windows the
list remains underneath route transitions, so entering and leaving a detail
never exposes a desktop placeholder.
Secondary routes use a continuous 240 ms fade with a short horizontal slide;
iOS retains its native transition and back gesture. Their transitions never
replace the underlying list with a plain background between pages.
Settings reading surfaces cap at 720 dp and the profile form at 560 dp.
`MaterialDetailCard` keeps section headings and rows on the same filled surface.
Space details expose rooms, members and management through three tabs, retaining
the existing add/edit/remove/leave actions. Contact details use a tonal profile
card with the actual Matrix ID and the existing conversation and copy actions;
the list and profile share the same duplicate-request and account-switch guards.

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

The available-update dialog groups the version, platform and package size in a
tonal summary card, followed by the release-note excerpt and full-notes link.
The Material dialog scrolls when its content exceeds the available height.

Material routes use Flutter's forward fade and horizontal slide on Android and
desktop; iOS keeps its native back gesture. `NeuColors` is also used as the
compatibility palette by shared widgets, so it interpolates every colour during
a theme transition instead of switching the whole palette halfway through.

## Desktop and tablet composers

Material uses one floating `surfaceContainerHigh` capsule at every pane width:
28 dp corners, a 56 dp default height and a 720 dp maximum surface width, with
16 dp side and 12 dp bottom margins. Its editor has no nested filled field.
Neu retains its compact input and the wide editor with a top divider.
Composer control shapes live in `material_theme.dart`: Material uses circular
icon controls and pill-shaped send buttons, while Neu retains its compact
rectangular controls. Thumbnail corners follow each skin's preview shape.
The device-local interaction
setting offers automatic, touch and keyboard/mouse modes. Automatic uses
keyboard/mouse on Linux, Windows and macOS, and touch on Android and iOS.
Keyboard/mouse targets are 32 dp; touch targets remain 48 dp. The mode also
controls plain-message drag selection, not hardware keyboard shortcuts or
secondary-click actions, which remain available in every mode.

Pane widths control layout; changing interaction mode never forces a wide
layout. The 600 dp expanded-editor threshold applies to Neu; Material keeps
its compact capsule at all widths.
Tablets follow system rotation, while phones retain the portrait preference.

Material interaction/startup choices use grouped radio rows with a
`secondaryContainer` selected fill. Attachment modes use the Material 3
navigation indicator and filled send actions on tonal surfaces, not Neu
shadows. Composer dialogs and menus inherit their theme's overlay shapes.

Staged images use a `surfaceContainerLow` card above the composer, with 18 dp
corners, a count, a clear action and 56 dp thumbnails. Sending disables both
clearing and individual removal. Neu retains its existing thumbnail strip.
The emoji and sticker picker uses the classic left-aligned tabs, compact emoji
grid and outlined sticker thumbnails in both themes. The active pack uses an
accent outline, and long-press previews use the floating rounded panel.
Video viewer counters use `labelMedium`; speed and menu controls share the
viewer pills, and volume uses the viewer's high-contrast slider colours.

Material code blocks retain the selected syntax theme, opacity and line numbers
inside a 12 dp frame; the language toolbar and copy action use Material surface,
text and button roles. Rich-message image placeholders use semantic surface and
icon colours in both brightnesses. Pending room-avatar previews match the circular
Material avatar, while Neu retains its rounded rectangle.

Notification message-mode selectors sit below their descriptions in Material.
Autocomplete identities allow two lines for each name and ID, with a row extent
derived from the active text scaler; keyboard scrolling uses that same extent.
The sent-message notice measures its themed label, retains a 48 dp minimum target
and clips its ink to the capsule. Send-flight start corners share the Material
composer's 28 dp radius; Neu retains its original motion geometry.

## Checking a change

Render the touched screen in both brightnesses at a phone width before and after.
A throwaway widget test does it: pump the page inside a `RepaintBoundary`, load
Roboto with `FontLoader` so text has glyphs, and write
`RenderRepaintBoundary.toImage` to a PNG outside the repository. Look for a card
that matches the surface it sits on, which means the page and card tones
collapsed, and for incorrectly paired text/container colour roles.

Test-environment caveat: the bundled test fonts have no CJK coverage, so Chinese
labels render as boxes. Read structure and tone from those shots, not labels.
