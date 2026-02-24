"""
TTS engine using OpenVoice V2 + MeloTTS.
Generates Korean speech with a Texas/American accent (reference voice).
"""
import os
import tempfile
import torch
from pathlib import Path

# Lazy init to avoid loading until first request
_tone_color_converter = None
_melo_model = None
_target_se = None
_kr_source_se = None


def _get_openvoice_root():
    """OpenVoice repo root (parent of this project or env)."""
    root = os.environ.get("OPENVOICE_ROOT")
    if root:
        return Path(root)
    # Assume OpenVoice is cloned alongside or inside project
    for p in [Path(__file__).resolve().parent.parent.parent / "OpenVoice", Path(__file__).resolve().parent.parent / "OpenVoice"]:
        if (p / "openvoice").exists():
            return p
    return Path(__file__).resolve().parent.parent / "OpenVoice"


def _get_ckpt_v2():
    return _get_openvoice_root() / "checkpoints_v2"


def _load_models():
    global _tone_color_converter, _melo_model, _target_se, _kr_source_se
    if _tone_color_converter is not None:
        return

    device = "cuda:0" if torch.cuda.is_available() else "cpu"
    openvoice_root = _get_openvoice_root()
    ckpt = _get_ckpt_v2()
    converter_dir = ckpt / "converter"
    if not converter_dir.exists():
        raise FileNotFoundError(
            f"OpenVoice V2 checkpoints not found at {ckpt}. "
            "Download from https://myshell-public-repo-host.s3.amazonaws.com/openvoice/checkpoints_v2_0417.zip and extract to checkpoints_v2/"
        )

    # Add OpenVoice to path and load
    import sys
    if str(openvoice_root) not in sys.path:
        sys.path.insert(0, str(openvoice_root))

    from openvoice import se_extractor
    from openvoice.api import ToneColorConverter
    from melo.api import TTS

    _tone_color_converter = ToneColorConverter(
        str(converter_dir / "config.json"), device=device
    )
    _tone_color_converter.load_ckpt(str(converter_dir / "checkpoint.pth"))

    # Reference voice: Texas/American accent (clone this voice)
    reference_path = os.environ.get(
        "TTS_REFERENCE_VOICE",
        str(openvoice_root / "resources" / "example_reference.mp3"),
    )
    if not os.path.isfile(reference_path):
        reference_path = str(ckpt / "reference" / "texas_american.mp3")
    if not os.path.isfile(reference_path):
        raise FileNotFoundError(
            f"Reference voice not found. Set TTS_REFERENCE_VOICE to a path to a short (3–10 s) "
            "American/Texas accent WAV/MP3, or add one at OpenVoice/resources/example_reference.mp3"
        )
    _target_se, _ = se_extractor.get_se(reference_path, _tone_color_converter, vad=True)

    # MeloTTS for Korean
    _melo_model = TTS(language="KR", device=device)
    speaker_ids = _melo_model.hps.data.spk2id
    first_speaker_key = next(iter(speaker_ids.keys()))
    ses_dir = ckpt / "base_speakers" / "ses"
    if not ses_dir.exists():
        raise FileNotFoundError(
            f"Base speakers dir not found: {ses_dir}. "
            "Extract checkpoints_v2 and ensure base_speakers/ses/ exists."
        )
    # Match OpenVoice V2 naming: often lowercase with hyphen (e.g. en-us, kr)
    for candidate in [
        first_speaker_key.lower().replace("_", "-"),
        first_speaker_key,
        "kr",
        "KR",
    ]:
        se_file = ses_dir / f"{candidate}.pth"
        if se_file.exists():
            break
    else:
        # Use first .pth in folder if no name match
        pth_files = list(ses_dir.glob("*.pth"))
        if not pth_files:
            raise FileNotFoundError(
                f"No .pth files in {ses_dir}. Check OpenVoice V2 base_speakers."
            )
        se_file = pth_files[0]
    _kr_source_se = torch.load(str(se_file), map_location=device)

    globals()["_tone_color_converter"] = _tone_color_converter
    globals()["_melo_model"] = _melo_model
    globals()["_target_se"] = _target_se
    globals()["_kr_source_se"] = _kr_source_se


def generate_korean_tts_american_accent(text: str, speed: float = 1.0) -> bytes:
    """
    Generate Korean TTS with Texas/American accent. Returns WAV bytes.
    """
    _load_models()
    device = _tone_color_converter.device

    with tempfile.TemporaryDirectory() as tmp:
        src_path = os.path.join(tmp, "kr_base.wav")
        out_path = os.path.join(tmp, "output.wav")

        # MeloTTS: Korean text -> base Korean speaker WAV
        speaker_id = _melo_model.hps.data.spk2id[next(iter(_melo_model.hps.data.spk2id))]
        _melo_model.tts_to_file(text, speaker_id, src_path, speed=speed, quiet=True)

        # OpenVoice: convert to American accent (reference voice)
        if torch.backends.mps.is_available() and device == "cpu":
            import torch
            torch.backends.mps.is_available = lambda: False
        _tone_color_converter.convert(
            audio_src_path=src_path,
            src_se=_kr_source_se,
            tgt_se=_target_se,
            output_path=out_path,
            message="@MyShell",
        )

        with open(out_path, "rb") as f:
            return f.read()
