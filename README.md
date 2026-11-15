# Tidy Parrot

Tap **fn**, speak, tap **fn** again: the text is pasted into whatever field has focus, with "um"s, "uh"s and
stutters removed. Press **Esc** while recording to discard it. The pill at the top of the screen appears on the tap, with a
spinner until the mic can hear you, then a chime plays (Tink) and the timer starts. Another chime plays when the mic
closes (Morse). A tap or Esc during the spinner cancels quietly, and a mic that stays silent for 3 s (muted, or
AirPods held by another device) ends the start with an alert. If what has focus can't take text, such as a button or a Finder file list, you hear a Pop and
recording doesn't start. Apps that don't say what has focus, such as Slack or VS Code, still record. If a
dictation went nowhere, click into the field and choose **Paste Last Dictation** from the menu. The last dictation
is kept in memory only, until you quit.

After 30 minutes without a dictation, the model is unloaded to free its memory (1–1.6 GB), and the menu says so. The
next tap records straight away while the model loads again, which takes about a second, so after a dictation of a
few seconds you don't wait at all.

Tech terms come out spelled the way you write them ("Datadog", "PostHog", "Next.js", "useEffect") because of a
vocabulary list. See [Vocabulary](#vocabulary).

macOS also acts on a plain fn tap (emoji picker, input source or Apple Dictation), and Tidy Parrot can't block that.
Set System Settings → Keyboard → **Press 🌐 key to** → **Do Nothing**.

A small menu-bar app in Swift, plus a Python helper that runs
[Fluid Speech Pro (MLX)](https://huggingface.co/FluidVoice-Labs/fluid-speech-pro-mlx) with clean mode on.

## Setup

Requires an Apple Silicon Mac on macOS 15 or later, Xcode, and Python 3.

```bash
make setup          # Python venv + pinned model download (~806 MB, into helper/model)
make run            # builds and opens build/TidyParrot.app (make run VERBATIM=1 keeps fillers)
```

`make help` lists everything else (tests, lint, format). The model is pinned to the revision
`helper/vendor/fluid_speech_mlx.py` was taken from, and loaded from `helper/model` with no network access at runtime.
To update, bump `MODEL_REVISION` in `scripts/setup.sh` and re-download the loader from the same revision.

The build writes the helper's absolute paths into the app, so rebuild after moving this folder.

On first launch macOS asks for two permissions:

- **Microphone:** to record between your fn taps. If it's off, the menu says so when you tap fn.
- **Accessibility:** to see the hotkey and paste. Turn on Tidy Parrot under System Settings → Privacy & Security →
  Accessibility. The app checks every second and starts the hotkey once it's allowed. This hasn't been tested yet;
  if the hotkey doesn't work, quit and reopen the app.

### Signing

macOS ties the Accessibility grant to the app's signature. Without a certificate the build is signed ad hoc, and an
ad-hoc signature changes with every build, so **each rebuild loses the grant**. Turning the switch off and on doesn't
help, because the list entry still points at the old build. To keep the grant, create a signing certificate once:

1. Open Keychain Access, then Keychain Access → Certificate Assistant → Create a Certificate…
2. Name it `Tidy Parrot Dev`, with Identity Type **Self-Signed Root** and Certificate Type **Code Signing**.
3. Double-click the new certificate, open **Trust**, and set **Code Signing** to **Always Trust**.
4. Run `make run`. The build no longer prints the ad-hoc warning.
5. One last time, remove Tidy Parrot from the Accessibility list with "−" and add it again. Later builds keep the grant.

To use a different certificate, such as an Apple Development one, run `make run SIGN_IDENTITY="its name"`.

## Vocabulary

Choose **Edit Vocabulary** in the menu to open `~/Library/Application Support/TidyParrot/vocabulary.txt`. It holds
one term per line, spelled and capitalised the way you want it typed. Lines starting with `#` are ignored. It starts
with about 75 front-end terms (frameworks, build tools, React hooks, services). Save it and the change applies
within a few seconds, with no restart.

The list is used in two ways:

- **Boost:** while decoding, the model is nudged towards your terms when what it hears is close.
- **Respelling:** after decoding, words that spell a term once spaces, case and punctuation are ignored are joined
  and recased: "data dog" → "Datadog", "next JS" → "Next.js", "use effect" → "useEffect". Terms that are
  also everyday words ("React", "Fallow", "Cypress") are skipped here, so "we need to react quickly" stays as said.

You don't list misspellings. What the list can't fix is a term that sounds like other words, such as "Qwik" and
"quick", or "CORS" and "course".

If a save can't be used (a line with no letters or digits, or a file that isn't UTF-8), the menu bar shows ⚠️ with
the line number, and the previous list stays in effect until you fix it or the helper restarts (after 30 minutes
idle, **Restart Helper**, or a relaunch), which leaves no terms. Empty the file, or delete it, to turn the
vocabulary off. To get the default list back, quit, delete the `TidyParrot` folder, and relaunch.
Option-click the icon to see how many terms are loaded and when. The ⚠️ and these details update with your next
dictation, not the moment you save: the helper reports them alongside each transcript.

Measured with synthetic voices on held-out sentences, with an earlier 154-term list: exactly right terms went from 43% to
76%, with no false hits on 30 trap sentences, and no added latency once the list is loaded. Expect lower numbers with
a real voice and mic. The list builds in about a second after the model loads, including after an idle unload;
dictation works without it meanwhile, so a dictation shorter than about 1.5 s right after a reload may miss it.

## How it works

```
fn down ─► an input-only Core Audio unit starts (fresh each time), closed again unless the press is a tap
fn up   ─► pill with a spinner; chime once the mic hears real audio; it stays open until the next tap
fn tap  ─► resample to 16 kHz mono ─► helper over stdin ─► text over stdout
        ─► clipboard + ⌘V ─► your clipboard restored 0.5 s later
```

- `app/`: Swift package. `TidyParrotCore` holds the app logic: a `DictationController` running hotkey → recorder →
  engine → paste, with each step behind a small protocol. `TidyParrot` is the executable that launches it.
  Only a plain fn tap toggles: fn used with another key (fn+arrows, fn+Delete) is left alone. The mic starts opening
  on fn key-down to save the length of the tap. A press that turns out to be a shortcut closes it again without a
  sound, though macOS may briefly show its mic indicator. Bluetooth mics open only on the tap, because opening one
  switches the headset to its call profile. The unit opens only the mic, not the output device, and the chime waits
  for three buffers of real audio in a row, because AirPods send silence for about a second while their call link
  comes up. Esc discards the recording, and the focused app still gets the Esc. Recordings stop after 3 minutes in case the stopping tap is
  missed, since password fields hide key events from other apps.
- `helper/`: `tidy_parrot_helper.py` loads the 8-bit model with clean mode once and warms it up, then answers one
  clip at a time over the protocol in `wire_protocol.py`. If the app quits or crashes, the helper's stdin closes and
  it exits. The app also stops it after 30 minutes idle and starts it again on the next tap; the clip from that tap
  waits until the model is ready. `vendor/fluid_speech_mlx.py` is FluidVoice's loader from the model repo, unmodified. `vocabulary.py`
  reads and watches the vocabulary file, `boost_table.py` turns it into a per-token bonus table, `decoding.py` is the
  greedy decoder that applies it, and `snap.py` respells the result.

See [AGENTS.md](AGENTS.md) for the full architecture, conventions and where to add features.

Menu bar icon: a parrot, with ⚠️ beside it when something needs attention (open the menu to see what). The parrot
is the Fluent UI Emoji parrot by Microsoft, under the MIT license in `app/Resources/MenuBarIcon-LICENSE.txt`.
Option-click the icon for diagnostics: helper state, model load time, the last dictation's timing and both permissions.
Logs: `~/Library/Logs/TidyParrot.log` (timings only, never the text), or **Open Log** in the menu.

## Measured on an M4 Pro

| | |
|---|---|
| Model load and warm-up | ~0.25–0.6 s (about 4 s the very first time, from a cold disk) |
| 4 s clip | 53–65 ms |
| 7 s clip | 76–123 ms |

## Testing

```bash
make test                                   # Swift + Python unit tests, no model needed
make integration WAV=some.wav               # Swift engine against the real helper and model
make smoke WAV=some.wav                     # the helper alone, over the app's protocol
helper/.venv/bin/python helper/tidy_parrot_helper.py --file some.wav [--verbatim]
```

## Known limits

- Clean mode removes fillers and most repeats. In testing it dropped "um", "uh" and "I I" but kept
  "we should we should".
- Paste uses key code 9 (V on QWERTY). Other keyboard layouts may need a different code.
- Recordings stop at 3 minutes and aren't split into chunks. Untested past a minute or so.
- `parakeet-mlx` is pinned, because the vendored loader patches its internals, `decoding.py` copies its greedy loop,
  and `boost_table.py` relies on its booster's internal state.
- The vocabulary is tested with about 150 terms. Much longer lists build more slowly and haven't been measured.

## Credits

Fluid Speech Pro by FluidVoice, CC BY 4.0. Built on NVIDIA Parakeet TDT 0.6B v3 and Moondream Parakeet Ultra.
