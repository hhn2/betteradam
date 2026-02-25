"""
FastAPI TTS service: Korean text -> MP3 with Texas/American accent (OpenVoice V2 + MeloTTS).
"""
import io
import os
import sys
import traceback
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

try:
    from tts_engine import generate_korean_tts_american_accent
except ModuleNotFoundError:
    from backend.tts_engine import generate_korean_tts_american_accent

app = FastAPI(title="Korean TTS (American accent)")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class TTSRequest(BaseModel):
    text: str


def wav_to_mp3(wav_bytes: bytes) -> bytes:
    """Convert WAV bytes to MP3 using pydub."""
    from pydub import AudioSegment
    seg = AudioSegment.from_wav(io.BytesIO(wav_bytes))
    buf = io.BytesIO()
    seg.export(buf, format="mp3", bitrate="128k")
    buf.seek(0)
    return buf.read()


@app.post("/api/tts")
def tts(request: TTSRequest):
    """Generate Korean TTS with American accent; returns MP3."""
    text = (request.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")
    if len(text) > 5000:
        raise HTTPException(status_code=400, detail="text too long (max 5000 chars)")
    try:
        wav_bytes = generate_korean_tts_american_accent(text)
        mp3_bytes = wav_to_mp3(wav_bytes)
        return Response(
            content=mp3_bytes,
            media_type="audio/mpeg",
            headers={"Content-Disposition": "attachment; filename=tts_output.mp3"},
        )
    except FileNotFoundError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        tb = traceback.format_exc()
        print(f"TTS ERROR:\n{tb}", file=sys.stderr)
        raise HTTPException(status_code=500, detail=f"{type(e).__name__}: {e}\n\n{tb}")


@app.get("/api/debug")
def debug():
    """Diagnostic endpoint — open in browser to check what's working."""
    results = {}

    # 1. Check Python version
    results["python"] = sys.version

    # 2. Check OpenVoice
    try:
        openvoice_root = os.environ.get("OPENVOICE_ROOT", "not set")
        results["OPENVOICE_ROOT"] = openvoice_root
        ckpt = os.path.join(openvoice_root, "checkpoints_v2", "converter", "checkpoint.pth")
        results["checkpoints_v2"] = "OK" if os.path.isfile(ckpt) else f"MISSING: {ckpt}"
    except Exception as e:
        results["openvoice"] = f"ERROR: {e}"

    # 3. Check imports
    for mod in ["torch", "openvoice", "melo", "pydub", "faster_whisper", "transformers", "tokenizers"]:
        try:
            m = __import__(mod)
            ver = getattr(m, "__version__", "ok")
            results[f"import_{mod}"] = ver
        except Exception as e:
            results[f"import_{mod}"] = f"ERROR: {e}"

    # 4. Check ffmpeg
    import shutil
    results["ffmpeg"] = shutil.which("ffmpeg") or "NOT FOUND"

    # 5. Check HuggingFace model cache (Korean only)
    try:
        from transformers import AutoTokenizer
        tok = AutoTokenizer.from_pretrained("kykim/bert-kor-base")
        results["model_bert_kor_base"] = "OK (cached)"
    except Exception as e:
        results["model_bert_kor_base"] = f"ERROR: {e}"

    return JSONResponse(results)


static_dir = os.path.join(os.path.dirname(__file__), "static")
index_path = os.path.join(static_dir, "index.html")


@app.get("/")
def index():
    return FileResponse(index_path)


if os.path.isdir(static_dir):
    app.mount("/static", StaticFiles(directory=static_dir), name="static")
