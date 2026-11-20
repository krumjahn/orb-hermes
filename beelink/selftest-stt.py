#!/usr/bin/env python3
"""
selftest-stt.py - prove that speech-to-text actually works.

This is the check that catches the decoder breakage: faster-whisper hands a
file path to PyAV, and PyAV 15+ dropped the 'metadata_errors' argument that
faster-whisper still passes to av.open(). With a new PyAV every single clip
fails with

    TypeError: open() got an unexpected keyword argument 'metadata_errors'

The bridge now reads the wav itself (see load_audio in hermes_bridge.py), so
this test uses the very same reader and the very same call the wake word
uses.

It transcribes real speech when edge-tts is available, and falls back to a
tone when it is not. Either way it fails loudly if the decoder is broken.
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.environ.get("ORB_BRIDGE", os.path.join(HERE, "hermes_bridge.py"))
MODEL = os.environ.get("WHISPER_MODEL", "base")


def load_bridge():
    spec = importlib.util.spec_from_file_location("orb_bridge", BRIDGE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_speech(folder):
    """A wav with real speech in it, if edge-tts can be used."""
    mp3 = os.path.join(folder, "speech.mp3")
    wav = os.path.join(folder, "speech.wav")
    try:
        subprocess.run(
            [sys.executable, "-m", "edge_tts", "--voice", "en-US-AriaNeural",
             "--text", "One two three.", "--write-media", mp3],
            check=True, capture_output=True, timeout=180,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"note: edge-tts unavailable ({exc}) - using a tone instead")
        return make_tone(folder), False

    # PyAV can still read an mp3 on every version; only the keyword that
    # faster-whisper passes is gone, and that is not used here.
    try:
        import av
        container = av.open(mp3)
        stream = container.streams.audio[0]
        resampler = av.audio.resampler.AudioResampler(
            format="s16", layout="mono", rate=16000,
        )
        with wave.open(wav, "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(16000)
            for frame in container.decode(stream):
                for resampled in resampler.resample(frame):
                    out.writeframes(resampled.to_ndarray().tobytes())
        container.close()
    except Exception as exc:  # noqa: BLE001
        print(f"note: could not decode the mp3 ({exc}) - using a tone instead")
        return make_tone(folder), False
    return wav, True


def make_tone(folder):
    """A quiet tone, so the test still exercises the whole decoder path."""
    import struct
    path = os.path.join(folder, "tone.wav")
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16000)
        samples = bytearray()
        for index in range(16000):
            value = int(3000 * (1 + 0.5 * ((index % 400) / 400.0)))
            samples += struct.pack("<h", value)
        out.writeframes(bytes(samples))
    return path


def main():
    bridge = load_bridge()
    folder = tempfile.mkdtemp()
    wav, real_speech = make_speech(folder)

    audio = bridge.load_audio(wav)
    if audio is None or len(audio) < 1600:
        print(f"FAIL: the wav reader returned {0 if audio is None else len(audio)} samples")
        return 1
    print(f"wav reader: {len(audio)} samples, peak {abs(audio).max():.4f}")

    from faster_whisper import WhisperModel
    model = WhisperModel(MODEL, device="cpu", compute_type="int8")

    segments, info = model.transcribe(audio)
    text = " ".join(segment.text.strip() for segment in segments).strip()
    print(f"transcribed: {text!r}")

    if real_speech and not text:
        print("FAIL: the speech was transcribed as nothing")
        return 1

    print("speech-to-text self-test OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
