#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"
source .venv/bin/activate

# Add static-ffmpeg to PATH so pydub can find it
FFMPEG_DIR="$(python -c "import static_ffmpeg, os; print(os.path.dirname(static_ffmpeg.run.get_or_fetch_platform_executables_else_raise()[0]))")"
export PATH="$FFMPEG_DIR:$PATH"
export OPENVOICE_ROOT="$(pwd)/OpenVoice"

# Make sure HuggingFace offline mode is off (models are cached by setup.sh)
unset HF_HUB_OFFLINE

echo "Starting server at http://localhost:8000 ..."
uvicorn backend.main:app --reload --host 0.0.0.0 --port 8000
