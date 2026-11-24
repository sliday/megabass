# megabass

A macOS menu-bar app that plays your music on the trackpad. Spotify, Music or YouTube keeps playing
through your speakers. megabass listens to the same audio and replays its low end on the Force Touch
haptic motor, cycle by cycle and in time with the speakers. Prominent notes above the bass (a sung
line, a lead) can ride along.

## Modes

| Mode | What the trackpad does |
|------|------------------------|
| **Bass** (default) | Replays the music's own waveform in the chosen band. Each bass period becomes one motor period at the same frequency. Above 160 Hz it adds any note that stands out from the mix and holds for 40 ms. |
| **Punch** | Kicks become thumps that dive down to the low handle, and a rumble follows the bass note. |
| **Harmony** | The trackpad sings a diatonic third above the bass (key estimated from the bass line). |

**Frequencies** strip: drag the left handle for how deep the haptics go, the right one for how
much of the song they play (20 Hz to 4 kHz). **Intensity** scales everything.

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

- `SystemTap`: a private Core Audio process tap on all output, so you don't need a virtual device or a driver.
- `CycleTracker`: band-passes the low band and cuts it into single periods at upward zero
  crossings. It emits each period as it starts, predicted from the previous one, which saves a period of lag.
- `ToneTracker`: every 10 ms, the strongest spectral peak in the upper band. It skips the bass
  overtones and requires 6× prominence plus a 40 ms steady hold.
- `HapticVoice`: a high-priority thread that schedules actuations for when the speakers play
  that audio (capture time + device output latency).
- `Motor`: the Force Touch actuator through the private MultitouchSupport framework.

## Checks

`swift build -c release --product mbcheck`, then:

| Command | Bar | Last result |
|---------|-----|-------------|
| `mbcheck cycles` | sines within 1 %, bass stem ≥ 85 % on note, no dropouts | 0.01 %, 100 %, 100 % |
| `mbcheck tones` | melody over groove ≥ 80 % on pitch, noise ≤ 5 % | 93 %, 0 % |
| `mbcheck pitch` | bass pitch class ≥ 90 %, kick recall ≥ 90 % within 30 ms | 92.8 %, 100 % at 20 ms |
| `mbcheck e2e 6 bass` | speakers → tap → motor, periods start within ±40 ms of the sound | +13 ms |
| `mbcheck live bass 20` | live log of whatever the Mac plays (needs the permission for the calling app) | |

## Credits

The trackpad-as-sound-source technique (MultitouchSupport actuations of sine "Tones") comes from
[nospeaker](https://github.com/os6/nospeaker) by Cody Collier, MIT License.
