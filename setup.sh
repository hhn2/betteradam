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

echo "=== 1/6  Creating Python 3.9 venv ==="
"$PYTHON" -m venv .venv
source .venv/bin/activate
pip install --upgrade pip "setuptools<82" wheel

echo "=== 2/6  Cloning & installing OpenVoice ==="
if [ ! -d "OpenVoice" ]; then
    git clone --depth 1 https://github.com/myshell-ai/OpenVoice.git
fi
pip install -e OpenVoice --no-deps

echo "=== 3/6  Installing MeloTTS + all deps ==="
# Shallow-clone MeloTTS (faster than pip install git+…, which clones full history)
if [ ! -d "_melotts_src" ]; then
    git clone --depth 1 https://github.com/myshell-ai/MeloTTS.git _melotts_src
fi
# Let pip resolve the full dep tree (--no-deps caused missing packages)
pip install --prefer-binary ./_melotts_src

# Ensure setuptools is present (v82+ removed pkg_resources; pin to <82)
pip install --force-reinstall "setuptools<82"

# Pin versions that must match for compatibility
pip install --prefer-binary \
    "av==14.2.0" \
    "faster-whisper>=1.0" \
    "wavmark==0.0.3" "numpy==1.22.0" \
    "whisper-timestamped==1.14.2" \
    "transformers==4.27.4" "tokenizers==0.13.3" "huggingface_hub==0.21.4" \
    mecab-ko-dic

# Force-reinstall g2pkk so we always patch a CLEAN file
# (prior broken runs may have left a corrupted g2pkk.py in site-packages)
pip install --force-reinstall --no-deps g2pkk

echo "=== 4/6  Patching packages for compatibility ==="
python << 'PATCH_SCRIPT'
import os, site, textwrap
sp = site.getsitepackages()[0]

def _read_clean(path):
    """Read a file as raw bytes, normalize all CR/CRLF to LF, return str."""
    with open(path, 'rb') as f:
        raw = f.read()
    return raw.replace(b'\r\n', b'\n').replace(b'\r', b'\n').decode('utf-8')

# --- Patch 1: MeloTTS HParams (handle int keys from newer huggingface_hub) ---
melo_utils = os.path.join(sp, "melo", "utils.py")
if os.path.isfile(melo_utils):
    src = _read_clean(melo_utils)
    old = '    def __getitem__(self, key):\n        return getattr(self, key)'
    new = textwrap.dedent('''\
    def __getitem__(self, key):
        if isinstance(key, int):
            keys = list(self.__dict__.keys())
            if key < len(keys):
                return self.__dict__[keys[key]]
            raise IndexError(key)
        return getattr(self, key)

    def __iter__(self):
        return iter(self.__dict__)''')
    new = '\n'.join('    ' + l if l.strip() else l for l in new.split('\n'))
    if old in src:
        with open(melo_utils, 'w') as f:
            f.write(src.replace(old, new))
        print("  Patched melo/utils.py (HParams)")
    else:
        print("  melo/utils.py already patched or not needed")

# --- Patch 2: g2pkk — use MeCab.Tagger + mecab-ko-dic for Korean POS ---
# g2pkk normally requires 'python-mecab-ko' (provides 'mecab' package),
# but that conflicts with 'mecab-python3' (provides 'MeCab' package)
# on macOS case-insensitive filesystems.
# Fix: (a) disable check_mecab auto-install, (b) patch get_mecab to use MeCab.Tagger.
g2pkk_file = os.path.join(sp, "g2pkk", "g2pkk.py")
if os.path.isfile(g2pkk_file):
    src = _read_clean(g2pkk_file)

    # Patch 2a: Disable check_mecab auto-install of python-mecab-ko
    old_check = ("    def check_mecab(self):\n"
                 "        if platform.system()=='Windows':\n"
                 "            spam_spec = importlib.util.find_spec(\"eunjeon\")\n"
                 "            non_found = spam_spec is None\n"
                 "            if non_found:\n"
                 "                print(f'you have to install eunjeon. install it...')\n"
                 "                p = subprocess.Popen('pip install eunjeon')\n"
                 "                p.wait()\n"
                 "        else:\n"
                 "            spam_spec = importlib.util.find_spec(\"mecab\")\n"
                 "            non_found = spam_spec is None\n"
                 "            if non_found:\n"
                 "                print(f'you have to install python-mecab-ko. install it...')\n"
                 "                p = subprocess.Popen([sys.executable, \"-m\", \"pip\", \"install\", 'python-mecab-ko'])\n"
                 "                p.wait()")
    new_check = ("    def check_mecab(self):\n"
                 "        # Patched: skip auto-install of python-mecab-ko (conflicts with mecab-python3)\n"
                 "        pass")
    if old_check in src:
        src = src.replace(old_check, new_check)
        print("  Patched g2pkk check_mecab (disabled auto-install)")
    else:
        print("  g2pkk check_mecab already patched or not found")

    # Patch 2b: Replace get_mecab to use MeCab.Tagger + mecab-ko-dic
    if "mecab_ko_dic" not in src:
        old_block = "                m = self.load_module_func('mecab')\n                return m.MeCab()"
        # Pre-formatted with correct indentation (16 spaces base)
        new_block = (
            "                import MeCab as _M\n"
            "                try:\n"
            "                    from mecab_ko_dic.ipadic import DICDIR as _dicdir\n"
            "                except ImportError:\n"
            "                    _dicdir = None\n"
            "\n"
            "                class _KoMeCabWrapper:\n"
            "                    def __init__(self):\n"
            "                        if _dicdir:\n"
            "                            self._t = _M.Tagger(f'-d {_dicdir}')\n"
            "                        else:\n"
            "                            self._t = _M.Tagger()\n"
            "                    def pos(self, text):\n"
            "                        node = self._t.parseToNode(text)\n"
            "                        tokens = []\n"
            "                        while node:\n"
            "                            if node.surface:\n"
            "                                feat = node.feature.split(',')\n"
            "                                tokens.append((node.surface, feat[0]))\n"
            "                            node = node.next\n"
            "                        return tokens\n"
            "                return _KoMeCabWrapper()"
        )

        if old_block in src:
            src = src.replace(old_block, new_block)
            print("  Patched g2pkk/g2pkk.py (Korean MeCab via MeCab.Tagger)")
        else:
            print("  WARNING: could not find expected code in g2pkk. Manual patching may be needed.")
    else:
        print("  g2pkk get_mecab already patched")

    # Save any changes
    with open(g2pkk_file, 'w') as f:
        f.write(src)
    print("  g2pkk file saved.")
else:
    print("  WARNING: g2pkk/g2pkk.py not found")

# --- Patch 3: MeloTTS cleaner.py — lazy-import language modules ---
# By default cleaner.py does `from . import chinese, japanese, english, ...`
# which forces japanese.py to load MeCab at import time even for Korean-only usage.
# Fix: overwrite with lazy-import version so only the requested language is loaded.
cleaner_file = os.path.join(sp, "melo", "text", "cleaner.py")
if os.path.isfile(cleaner_file):
    src = _read_clean(cleaner_file)
    if "from . import chinese, japanese" in src:
        with open(cleaner_file, 'w') as f:
            f.write(textwrap.dedent('''\
                from . import cleaned_text_to_sequence
                import copy
                import importlib

                _LANG_MODULE_NAMES = {
                    'ZH': 'chinese', 'JP': 'japanese', 'EN': 'english',
                    'ZH_MIX_EN': 'chinese_mix', 'KR': 'korean',
                    'FR': 'french', 'SP': 'spanish', 'ES': 'spanish',
                }
                _loaded = {}

                def _get_language_module(language):
                    if language not in _loaded:
                        name = _LANG_MODULE_NAMES[language]
                        _loaded[language] = importlib.import_module('.' + name, package='melo.text')
                    return _loaded[language]

                class _LazyMap(dict):
                    def __getitem__(self, key):
                        return _get_language_module(key)
                    def __contains__(self, key):
                        return key in _LANG_MODULE_NAMES

                language_module_map = _LazyMap()


                def clean_text(text, language):
                    language_module = language_module_map[language]
                    norm_text = language_module.text_normalize(text)
                    phones, tones, word2ph = language_module.g2p(norm_text)
                    return norm_text, phones, tones, word2ph


                def clean_text_bert(text, language, device=None):
                    language_module = language_module_map[language]
                    norm_text = language_module.text_normalize(text)
                    phones, tones, word2ph = language_module.g2p(norm_text)

                    word2ph_bak = copy.deepcopy(word2ph)
                    for i in range(len(word2ph)):
                        word2ph[i] = word2ph[i] * 2
                    word2ph[0] += 1
                    bert = language_module.get_bert_feature(norm_text, word2ph, device=device)

                    return norm_text, phones, tones, word2ph_bak, bert


                def text_to_sequence(text, language):
                    norm_text, phones, tones, word2ph = clean_text(text, language)
                    return cleaned_text_to_sequence(phones, tones, language)


                if __name__ == "__main__":
                    pass
            '''))
        print("  Patched melo/text/cleaner.py (lazy language imports — no more Japanese at startup)")
    else:
        print("  melo/text/cleaner.py already patched")
else:
    print("  WARNING: melo/text/cleaner.py not found")

# --- Create mecabrc pointing to Korean dictionary (belt & suspenders) ---
import shutil
mecabrc_path = os.path.join(os.path.dirname(sp), '..', '..', '..', 'mecabrc')
mecabrc_path = os.path.normpath(os.path.join(os.environ.get('VIRTUAL_ENV', sp), 'mecabrc'))
try:
    from mecab_ko_dic.ipadic import DICDIR
    with open(mecabrc_path, 'w') as f:
        f.write(f'dicdir = {DICDIR}\n')
    print(f"  Created mecabrc at {mecabrc_path} → {DICDIR}")
except Exception as e:
    print(f"  WARNING: could not create mecabrc: {e}")
PATCH_SCRIPT

echo "=== 5/6  Pre-downloading models & checkpoints ==="
unset HF_HUB_OFFLINE
python -c "
from huggingface_hub import snapshot_download
# Only Korean BERT model is needed (Japanese/English are not used)
for repo in ['kykim/bert-kor-base']:
    print(f'  Downloading {repo}...')
    snapshot_download(repo, ignore_patterns=['*.msgpack', '*.h5', '*.ot', 'tf_*', 'flax_*', 'rust_*'])
print('  Korean model cached.')
"

if [ ! -d "OpenVoice/checkpoints_v2" ]; then
    echo "  Downloading OpenVoice V2 checkpoints..."
    curl -L -o /tmp/ckpt_v2.zip \
        "https://myshell-public-repo-host.s3.amazonaws.com/openvoice/checkpoints_v2_0417.zip"
    unzip -o /tmp/ckpt_v2.zip -d OpenVoice
    rm /tmp/ckpt_v2.zip
fi

echo "=== 6/6  Installing backend deps + static ffmpeg ==="
pip install -r backend/requirements.txt static-ffmpeg
python -c "import static_ffmpeg; static_ffmpeg.run.get_or_fetch_platform_executables_else_raise()"

echo ""
echo "=== Verifying installation ==="
export MECABRC="$(pwd)/.venv/mecabrc"
python << 'VERIFY'
import sys
errors = []

for mod in ['torch', 'transformers', 'tokenizers', 'huggingface_hub']:
    try:
        m = __import__(mod)
        print(f'  ✓ {mod} {getattr(m, "__version__", "ok")}')
    except Exception as e:
        errors.append(f'{mod}: {e}'); print(f'  ✗ {mod}: {e}')

try:
    from melo.api import TTS; print('  ✓ melo (MeloTTS)')
except Exception as e:
    errors.append(f'melo: {e}'); print(f'  ✗ melo: {e}')

try:
    from openvoice.api import ToneColorConverter; print('  ✓ openvoice')
except Exception as e:
    errors.append(f'openvoice: {e}'); print(f'  ✗ openvoice: {e}')

try:
    from g2pkk import G2p
    g = G2p()
    result = g('테스트')
    print(f'  ✓ g2pkk (Korean G2P) → {result}')
except Exception as e:
    errors.append(f'g2pkk: {e}'); print(f'  ✗ g2pkk: {e}')

import shutil
ff = shutil.which('ffmpeg')
if ff: print(f'  ✓ ffmpeg ({ff})')
else: errors.append('ffmpeg not in PATH'); print('  ✗ ffmpeg not found')

from transformers import AutoTokenizer
for model in ['kykim/bert-kor-base']:
    try:
        AutoTokenizer.from_pretrained(model, local_files_only=True)
        print(f'  ✓ model: {model}')
    except Exception:
        errors.append(f'model not cached: {model}')
        print(f'  ✗ model: {model}')

if errors:
    print(f'\n⚠️  {len(errors)} PROBLEM(S):')
    for e in errors: print(f'   • {e}')
    sys.exit(1)
else:
    print('\n✅ All checks passed! Run the server with: ./run.sh')
VERIFY
