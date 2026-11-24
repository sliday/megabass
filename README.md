# megabass

<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt="megabass icon: a trackpad with glowing haptic rings"></p>

A macOS menu-bar app that plays your music on the trackpad. Spotify, Music, YouTube or
[cliamp](https://github.com/bjarneo/cliamp) keeps playing through your speakers. megabass listens to
the same audio and replays its low end on the Force Touch haptic motor, cycle by cycle and in time
with the speakers. Notes that stand out above the bass (a sung line, a lead) can ride along.

<p align="center"><img src="docs/demo.gif" width="320" alt="megabass panel: power ring pulsing with the bass, cliamp now playing, live spectrum with the frequency handles, modes"></p>
<p align="center"><a href="docs/demo.mp4">Watch with sound (MP4)</a></p>

## Use it

Click the power button. The ring pulses with the bass and the trackpad starts to play.

| Control | What it does |
|---------|--------------|
| **Bass** (default) | Replays the music's own waveform in the chosen band. Each bass period becomes one motor period at the same frequency. Above 160 Hz it adds notes that stand out from the mix and hold for 40 ms. |
| **Punch** | Kicks become thumps that dive to the left handle; a rumble follows the bass note. |
| **Harmony** | The trackpad sings a diatonic third above the bass (key estimated from the bass line). |
| **Frequencies** | The live spectrum of what your Mac plays, 20 Hz to 4 kHz. The bars between the two handles glow: that's what the trackpad plays. Left handle: how deep. Right handle: how much of the song (Bass, Voices, Melody). |
| **Intensity** | How hard the motor works. |
| **Now playing** | Shows cliamp's track and controls it (previous, play/pause, next). If cliamp is idle, **Play** starts one of your playlists through its headless daemon. |

Can't see the menu-bar icon? A menu-bar manager such as Bartender, or the notch, may hide it.
Open megabass again from Spotlight, Alfred or Finder and its panel appears as a floating window.

## Build and run

Needs macOS 14.4+ (Core Audio process taps), Apple Silicon, a Force Touch trackpad and the Command
Line Tools.

```sh
./build.sh && open build/megabass.app
```

On first switch-on macOS asks for **System Audio Recording**. Without it the tap hears only
silence from other apps. **Play demo** works without any permission.

The build is ad-hoc signed, so macOS may ask for the permission again after a rebuild.

## How it works

- `SystemTap`: a private Core Audio process tap on all output. You don't need a virtual device or driver.
- `CycleTracker`: band-passes the low band and cuts it into single periods at upward zero
  crossings. It emits each period as it starts, predicted from the previous one, which saves a period of lag.
- `ToneTracker`: every 10 ms, the strongest spectral peak in the upper band. It skips the bass
  overtones and requires 6× prominence plus a 40 ms steady hold.
- `SpectrumAnalyzer`: 40 log bands, 20 Hz to 4 kHz, drawn as the Frequencies track.
- `HapticVoice`: a high-priority thread that schedules actuations for when the speakers play
  that audio (capture time + device output latency).
- `Motor`: the Force Touch actuator through the private MultitouchSupport framework.
- `CliampBridge`: cliamp's CLI/IPC (`status --json`, `toggle`, `next`, `load`). It polls only while the panel is open.

## Checks

`swift build -c release --product mbcheck`, then:

| Command | Bar | Last result |
|---------|-----|-------------|
| `mbcheck cycles` | sines within 1 %, bass stem ≥ 85 % on note, no dropouts | 0.01 %, 100 %, 100 % |
| `mbcheck tones` | melody over groove ≥ 80 % on pitch, noise ≤ 5 % | 93 %, 0 % |
| `mbcheck pitch` | bass pitch class ≥ 90 %, kick recall ≥ 90 % within 30 ms | 92.8 %, 100 % at 20 ms |
| `mbcheck e2e 6 bass` | speakers → tap → motor, periods start within ±40 ms of the sound | +13 ms |
| `mbcheck live bass 20` | live log of whatever the Mac plays (the calling app needs the permission) | |

Real music through the app: launch with `--on --diag /path/to/diag.txt` for a once-a-second line of
input level, bass periods/s, tones/s, actuations/s and sync. With cliamp playing lofi: −16 dBFS in,
58-73 periods/s, 62-75 actuations/s, +1 to +21 ms after the speakers.

## Icon

`tools/replicate_icon.py` generates candidates on Replicate (`openai/gpt-image-2.6-sunburst`) from
`tools/icon_prompt.txt`; `tools/pack_icon.sh` packs a 1024 px PNG into `AppIcon.icns`. The art is
full bleed so macOS 26 applies its own mask.

## Credits

The trackpad-as-sound-source technique (MultitouchSupport actuations of sine "Tones") comes from
[nospeaker](https://github.com/os6/nospeaker) by Cody Collier, MIT License. The player integration
drives [cliamp](https://github.com/bjarneo/cliamp) by Bjarne Øverli, MIT License.
