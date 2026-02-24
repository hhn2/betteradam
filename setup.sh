#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"
ROOT="$(pwd)"

# --- Find Python 3.9 ---
PYTHON=""
for cmd in python3.9 python3 python; do
    if command -v "$cmd" &>/dev/null; then
        ver=$("$cmd" --version 2>&1 | grep -oE '3\.[0-9]+')
        if [[ "$ver" == "3.9" || "$ver" == "3.10" ]]; then
            PYTHON="$cmd"
            break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    echo "ERROR: Python 3.9 (or 3.10) is required but not found."
    echo ""
    echo "  Your python3 is: $(python3 --version 2>&1)"
    echo ""
    echo "  Install Python 3.9:"
    echo "    macOS:   brew install python@3.9"
    echo "    Ubuntu:  sudo apt install python3.9 python3.9-venv"
    echo "    pyenv:   pyenv install 3.9.18 && pyenv local 3.9.18"
    echo ""
    exit 1
fi

echo "Using: $PYTHON ($($PYTHON --version))"

echo "=== 1/7  Creating Python 3.9 venv ==="
"$PYTHON" -m venv .venv
source .venv/bin/activate
pip install --upgrade pip

echo "=== 2/7  Installing pre-built PyAV (skip pkg-config/ffmpeg) ==="
pip install av --only-binary av

echo "=== 3/7  Cloning & installing OpenVoice ==="
if [ ! -d "OpenVoice" ]; then
    git clone https://github.com/myshell-ai/OpenVoice.git
fi
pip install -e OpenVoice --no-deps

echo "=== 4/7  Installing MeloTTS + OpenVoice deps ==="
pip install "faster-whisper>=1.0" --only-binary :all:
pip install \
    "librosa==0.9.1" "pydub==0.25.1" "wavmark==0.0.3" "numpy==1.22.0" \
    "eng_to_ipa==0.0.2" "inflect==7.0.0" "unidecode==1.3.7" \
    "whisper-timestamped==1.14.2" "pypinyin==0.50.0" "cn2an==0.5.22" \
    "jieba==0.42.1" "langid==1.1.6"
pip install git+https://github.com/myshell-ai/MeloTTS.git
pip install "transformers==4.27.4" "tokenizers==0.13.3" "huggingface_hub==0.21.4"
python -m unidic download

echo "=== 5/7  Patching MeloTTS HParams for compatibility ==="
python -c "
path = __import__('melo.utils', fromlist=['utils']).__file__
with open(path) as f: src = f.read()
old = '    def __getitem__(self, key):\n        return getattr(self, key)'
new = '    def __getitem__(self, key):\n        if not isinstance(key, str): raise TypeError(f\"HParams key must be str, got {type(key).__name__}\")\n        return getattr(self, key)'
if old in src:
    with open(path, 'w') as f: f.write(src.replace(old, new))
    print('  Patched.')
else:
    print('  Already patched or not needed.')
"

echo "=== 6/7  Pre-downloading HuggingFace models ==="
python -c "
from huggingface_hub import snapshot_download
for repo in ['bert-base-uncased', 'tohoku-nlp/bert-base-japanese-v3', 'kykim/bert-kor-base']:
    print(f'  Downloading {repo}...')
    snapshot_download(repo, ignore_patterns=['*.msgpack', '*.h5', '*.ot', 'tf_*', 'flax_*', 'rust_*'])
print('  All models cached.')
"

echo "=== 6/7  Downloading OpenVoice V2 checkpoints ==="
if [ ! -d "OpenVoice/checkpoints_v2" ]; then
    curl -L -o /tmp/ckpt_v2.zip \
        "https://myshell-public-repo-host.s3.amazonaws.com/openvoice/checkpoints_v2_0417.zip"
    unzip -o /tmp/ckpt_v2.zip -d OpenVoice
    rm /tmp/ckpt_v2.zip
fi

echo "=== 7/7  Installing backend deps + static ffmpeg ==="
pip install -r backend/requirements.txt static-ffmpeg
python -c "import static_ffmpeg; static_ffmpeg.run.get_or_fetch_platform_executables_else_raise()"

echo ""
echo "============================================"
echo "  Setup complete!  Run the server with:"
echo ""
echo "    source .venv/bin/activate"
echo "    ./run.sh"
echo "============================================"
