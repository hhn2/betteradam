# Korean TTS — Texas American accent

Simple TTS service: type Korean text, get an MP3 spoken with a **Texas American accent** (strong English accent reading Korean). Built with **MyShell’s OpenVoice V2** and **MeloTTS**.

## What you get

- A single-page UI: textbox for Korean input, **Generate** → play in the browser and **Download MP3**.

## Setup

**Important:** OpenVoice and MeloTTS only work with **Python 3.9** (or 3.10 at most). Python 3.11+, 3.14, etc. will fail (wrong numpy, setuptools, or missing wheels). Use conda or a venv created with Python 3.9.

### 1. OpenVoice + MeloTTS (one-time)

**Check your Python version first:** run `python --version` or `python3.9 --version`. You must see **3.9.x**. If you don’t have 3.9:

- **macOS (Homebrew):** `brew install python@3.9` then use `python3.9` in the commands below.
- **pyenv:** `pyenv install 3.9.18` then `pyenv local 3.9.18` in your project folder.
- **python.org:** install the 3.9.x Windows/macOS installer and use that `python` or `py -3.9`.

**System deps (fixes "pkg-config is required for building PyAV"):**

- **macOS (Homebrew):** `brew install pkg-config ffmpeg`
- **Ubuntu/Debian:** `sudo apt install pkg-config libavformat-dev libavcodec-dev libavdevice-dev libavutil-dev libavfilter-dev libswscale-dev`

From your workspace (e.g. same folder as this repo):

**Option A — with conda**

```bash
conda create -n openvoice python=3.9
conda activate openvoice
git clone https://github.com/myshell-ai/OpenVoice.git
cd OpenVoice
pip install -e .
```

**Option B — without conda (venv)**

```bash
# Create venv with Python 3.9 (not 3.10+, not 3.14)
python3.9 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
# Confirm: python --version  → 3.9.x

git clone https://github.com/myshell-ai/OpenVoice.git
cd OpenVoice
pip install -e .
```

Then (same env active):

Download **OpenVoice V2** checkpoints and unzip into `OpenVoice/checkpoints_v2/`:

- https://myshell-public-repo-host.s3.amazonaws.com/openvoice/checkpoints_v2_0417.zip

Install **MeloTTS** (required for V2). If the git install times out, retry or use a different network:

```bash
pip install git+https://github.com/myshell-ai/MeloTTS.git
python -m unidic download
```

### 2. Texas / American reference voice

OpenVoice clones the **accent and tone** from a short reference recording. For a Texas American sound:

- **Option A:** Use the default `OpenVoice/resources/example_reference.mp3` if it’s American.
- **Option B:** Add your own 3–10 second WAV/MP3 of a Texan/American speaker (any language) and set:

  ```bash
  export TTS_REFERENCE_VOICE="/path/to/your/texas_reference.mp3"
  ```

Put the file in `OpenVoice/resources/` and point `TTS_REFERENCE_VOICE` to it, or place it at `OpenVoice/checkpoints_v2/reference/texas_american.mp3` and the app will use it if present.

### 3. This TTS service

```bash
cd backend
pip install -r requirements.txt
```

Run the API (from the **same venv/conda env** where OpenVoice and MeloTTS are installed, and from the repo root so `OpenVoice` is a sibling of `backend` or set `OPENVOICE_ROOT`):

```bash
# From repo root (e.g. betteradam/)
export OPENVOICE_ROOT="$(pwd)/OpenVoice"   # if OpenVoice is cloned here
uvicorn backend.main:app --reload --host 0.0.0.0 --port 8000
```

If OpenVoice is already in `PYTHONPATH` and the app runs from repo root, you can try without the env:

```bash
uvicorn backend.main:app --reload --host 0.0.0.0 --port 8000
```

Open **http://localhost:8000** → type Korean → **Generate** → play and download MP3.

## Project layout

- `backend/main.py` — FastAPI app; `POST /api/tts` returns MP3.
- `backend/tts_engine.py` — Calls MeloTTS (Korean) then OpenVoice (apply American/Texas reference voice).
- `backend/static/index.html` — UI: textbox, Generate, play, download.

## Env (optional)

| Variable | Meaning |
|----------|--------|
| `OPENVOICE_ROOT` | Path to the OpenVoice repo (so the app can find `checkpoints_v2` and `openvoice`). |
| `TTS_REFERENCE_VOICE` | Path to WAV/MP3 of the Texas/American reference voice (3–10 s). |

## Troubleshooting

- **Python 3.14 / 3.11+:** You'll see errors like `numpy==1.22.0` failing or `Cannot import 'setuptools.build_meta'`. OpenVoice and MeloTTS expect **Python 3.9**. Create a new venv with 3.9 (see "Check your Python version first" above) and run all steps inside it.
- **"No module named unidic":** MeloTTS wasn't installed (e.g. the `pip install git+https://...MeloTTS.git` step failed or timed out). Use Python 3.9, then run `pip install git+https://github.com/myshell-ai/MeloTTS.git` again; after it succeeds, run `python -m unidic download`.
- **pip timeout installing MeloTTS:** Retry, or try another network. You can also clone the repo and install locally: `git clone https://github.com/myshell-ai/MeloTTS.git && pip install -e ./MeloTTS`.
- **"pkg-config is required for building PyAV":** Install system deps so PyAV (used by audio libs) can build. On macOS: `brew install pkg-config ffmpeg`. Then retry `pip install -e .` or the MeloTTS install.
- **PyAV "Cython.Compiler.Errors.CompileError: av/logging.pyx":** Pip is building av from source and Cython 3.x breaks it. **Fix 1** — force a pre-built wheel: `pip install av --only-binary av`. If your platform has no wheel for av 10 (e.g. "No matching distribution for av>=10,<11"), use **Fix 2** — build av 10 with old Cython: run `pip install "cython>=0.29,<3"`, then `pip install "av>=10,<11" --no-build-isolation`, then `pip install -e .` from the OpenVoice directory. If you see `TimeoutError: [Errno 60]` during av build, fix the corrupted setuptools first: `rm -rf .venv-openvoice/lib/python3.9/site-packages/-etuptools*` then retry. **Conda:** `conda install -c conda-forge av` then run your pip installs.

## Note

The “Texas” sound comes from the **reference audio** you provide. Use a short clip of a Texan or strong American accent for best results.
