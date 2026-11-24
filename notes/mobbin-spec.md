# megabass popover: Mobbin pattern spec

Access note: the Chrome extension was offline and Mobbin returns 403 to logged-out fetches on search
and screen pages. Nobody logged in. Sources below come from Mobbin's indexed screen metadata
(titles, tags, descriptions) plus its public glossary. I saw no screenshots, so visual specifics
(colors, glow, sizes) are my inference from these patterns, marked [inferred].

## Sources (Mobbin, metadata only)
- Spotify iOS, Equalizer: EQ curve graph, preset picker, frequency sliders (tags: Settings, Slider).
- Sonos iOS, EQ Settings: three sliders (Bass, Treble, Balance) plus a Loudness toggle.
- Deezer Android, Setting equalizer flow (7 screens): enable switch first, then preset modal
  (Normal / Classical / Dance / Rock / User), bass boost, surround.
- Deezer Android, Equalizer Enabled: frequency bands appear only after the master toggle is on.
- Opera iOS, Turning on VPN flow (6 screens, tag Turning On/Off): one master switch gates the feature.
- IKEA Home smart iOS, Brightness Control sheet: one big intensity slider in a bottom sheet.
- Dropbox iOS, Image Adjust (Dark Mode): segmented control stacked above a slider on dark ground.
- Mobbin glossary: Slider, Segmented Control.

## Layout (top to bottom, ~300px wide)
1. Header row: wordmark left, status text right ("Listening" / "Off"). 12px type.
2. Hero: big circular power button, centered, ~96px, with the live bass meter as a ring around it.
3. Mode picker: 3-segment control, full width, equal segments.
4. Intensity slider: label left, value right on one line, track below.
5. Footer: hairline divider, "Quit megabass" text link, right-aligned or centered.
Pattern origin: Deezer and Opera both put the master on/off first and reveal or enable the
tuning controls after it. Sonos and IKEA keep the tuning surface to one or three sliders.

## Visual hierarchy [inferred]
- Ground: near-black (#0B0B0F) under the native popover vibrancy; panels one step lighter (#16161C).
- One accent with glow: hot magenta or electric cyan. Use it only for the ON state, meter, the
  selected segment and the slider fill. Everything else stays gray (#8A8A96 secondary text).
- Glow: an outer shadow in the accent color at 30 to 50 percent opacity, blur 16 to 24px, on the
  power button and meter only. Glow everywhere reads as noise.
- Type: SF Pro. Status 11 to 12px semibold caps with tracking; mode labels 12px medium;
  intensity value in SF Mono or tabular digits so the number does not jitter.
- Spacing: 16px outer padding, 12px between sections, 8px inside groups.

## Interactions
- Power toggle: OFF is a dim gray ring with an outline icon. ON fills with the accent, starts
  the glow, and the ring meter goes live. Animate 150 to 200ms ease-out. Effect applies at once
  (glossary: toggles and segments act instantly, no Save button).
- Meter: ring segments or a short bar row react to bass energy. Use fast attack (~30ms) and slow
  release (~250ms) so it pulses with kicks instead of flickering. Idle when OFF: flat, gray.
- Segmented control: three equal segments on one shared track (glossary: a shared track is what
  separates it from tabs). Selected segment gets the accent fill; a sliding thumb animates between.
- Slider: continuous, with the value shown beside the label (glossary: continuous sliders usually
  hide values, but a haptics app benefits from a visible number). Fire a light trackpad tick at
  25/50/75 percent as a built-in demo of the feature.
- When OFF: mode picker and slider stay visible at about 40 percent opacity but remain usable,
  so you can preset before turning on. Deezer hides them; in a 300px popover dimming beats layout shift.

## Recommendations for the 300px dark popover
1. Make the power button the only large element: about 96px, centered, accent plus glow when ON.
2. Wrap the meter around the button as a ring so the visualizer and toggle share one focal point.
3. Use one accent color with glow on at most three things: button, meter, selected segment.
4. Build the mode picker as a native-feeling 3-segment control with a sliding thumb; give each mode
   a tiny icon (single pulse, wave, chord) above or beside the label for fast scanning.
5. Show intensity as a percent in tabular digits on the label row; avoid tick marks for 0 to 100.
6. Keep controls live when OFF at reduced opacity; do not collapse the popover height.
7. Add a one-word status line ("Listening", "No audio", "Off") so a flat meter never looks broken.
8. Quit as a quiet text link in the footer with a hairline above it, plus Cmd+Q as the shortcut.

Do not copy any app's branding, icons or exact palette; the list above records patterns only.
