#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"
ROOT="$(pwd)"

echo "=== 1/6  Creating Python 3.9 venv ==="
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip

echo "=== 2/6  Installing pre-built PyAV (skip pkg-config/ffmpeg) ==="
pip install av --only-binary av

echo "=== 3/6  Cloning & installing OpenVoice ==="
if [ ! -d "OpenVoice" ]; then
    git clone https://github.com/myshell-ai/OpenVoice.git
fi
pip install -e OpenVoice --no-deps

echo "=== 4/6  Installing MeloTTS + OpenVoice deps ==="
pip install "faster-whisper>=1.0" --only-binary :all:
pip install \
    "librosa==0.9.1" "pydub==0.25.1" "wavmark==0.0.3" "numpy==1.22.0" \
    "eng_to_ipa==0.0.2" "inflect==7.0.0" "unidecode==1.3.7" \
    "whisper-timestamped==1.14.2" "pypinyin==0.50.0" "cn2an==0.5.22" \
    "jieba==0.42.1" "langid==1.1.6"
pip install git+https://github.com/myshell-ai/MeloTTS.git
pip install "transformers==4.27.4" "tokenizers==0.13.3"
python -m unidic download

echo "=== 5/7  Pre-downloading HuggingFace models needed by MeloTTS ==="
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
