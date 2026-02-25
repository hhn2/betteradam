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
    mecab-ko-dic mecab-python3

# Force-reinstall g2pkk so we always patch a CLEAN file
# (prior broken runs may have left a corrupted g2pkk.py in site-packages)
pip install --force-reinstall --no-deps g2pkk

# Ensure system mecab library is available (needed by mecab-python3)
if [[ "$(uname)" == "Darwin" ]]; then
    if ! command -v mecab &>/dev/null; then
        echo "  Installing mecab via Homebrew..."
        if command -v brew &>/dev/null; then
            brew install mecab
        else
            echo "  WARNING: Homebrew not found. Install mecab manually: brew install mecab"
        fi
    fi
elif [[ "$(uname)" == "Linux" ]]; then
    if ! command -v mecab &>/dev/null; then
        echo "  Installing mecab via apt..."
        sudo apt-get install -y mecab libmecab-dev 2>/dev/null || \
            echo "  WARNING: Could not install mecab. Install manually: sudo apt install mecab libmecab-dev"
    fi
fi

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

# --- Patch 2: g2pkk — replace entire file with version using MeCab.Tagger ---
# The original g2pkk requires 'python-mecab-ko' which conflicts with 'mecab-python3'
# on macOS case-insensitive filesystem. Also, get_mecab() silently returns None on error.
# Fix: overwrite the entire file with a corrected version.
g2pkk_file = os.path.join(sp, "g2pkk", "g2pkk.py")
if os.path.isfile(g2pkk_file):
    with open(g2pkk_file, 'w') as f:
        f.write('''\
# -*- coding: utf-8 -*-
# Patched by betteradam setup.sh — uses mecab-python3 + mecab-ko-dic
# instead of python-mecab-ko (which conflicts on macOS case-insensitive FS).

import os, re, platform, sys, importlib
import subprocess

import nltk
from jamo import h2j
from nltk.corpus import cmudict

try:
    nltk.data.find('corpora/cmudict.zip')
except LookupError:
    nltk.download('cmudict')

from g2pkk.special import jyeo, ye, consonant_ui, josa_ui, vowel_ui, jamo, rieulgiyeok, rieulbieub, verb_nieun, balb, palatalize, modifying_rieul
from g2pkk.regular import link1, link2, link3, link4
from g2pkk.utils import annotate, compose, group, gloss, parse_table, get_rule_id2text
from g2pkk.english import convert_eng
from g2pkk.numerals import convert_num


class G2p(object):
    def __init__(self):
        self.mecab = self._make_mecab()
        self.table = parse_table()
        self.cmu = cmudict.dict()
        self.rule2text = get_rule_id2text()
        self.idioms_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "idioms.txt")

    @staticmethod
    def _make_mecab():
        """Return a MeCab wrapper with a .pos() method, using mecab-python3 + mecab-ko-dic."""
        import MeCab as _M
        try:
            from mecab_ko_dic.ipadic import DICDIR as _dicdir
        except ImportError:
            _dicdir = None

        class _KoMeCabWrapper:
            def __init__(self):
                if _dicdir:
                    self._t = _M.Tagger(f"-d {_dicdir}")
                else:
                    self._t = _M.Tagger()
            def pos(self, text):
                node = self._t.parseToNode(text)
                tokens = []
                while node:
                    if node.surface:
                        feat = node.feature.split(",")
                        tokens.append((node.surface, feat[0]))
                    node = node.next
                return tokens

        return _KoMeCabWrapper()

    def idioms(self, string, descriptive=False, verbose=False):
        rule = "from idioms.txt"
        out = string
        with open(self.idioms_path, 'r', encoding="utf8") as f:
            for line in f:
                line = line.split("#")[0].strip()
                if "===" in line:
                    str1, str2 = line.split("===")
                    out = re.sub(str1, str2, out)
            gloss(verbose, out, string, rule)
        return out

    def __call__(self, string, descriptive=False, verbose=False, group_vowels=False, to_syl=True):
        string = self.idioms(string, descriptive, verbose)
        string = convert_eng(string, self.cmu)
        string = annotate(string, self.mecab)
        string = convert_num(string)
        inp = h2j(string)
        for func in (jyeo, ye, consonant_ui, josa_ui, vowel_ui,
                     jamo, rieulgiyeok, rieulbieub, verb_nieun,
                     balb, palatalize, modifying_rieul):
            inp = func(inp, descriptive, verbose)
        inp = re.sub("/[PJEB]", "", inp)
        for str1, str2, rule_ids in self.table:
            _inp = inp
            inp = re.sub(str1, str2, inp)
            if len(rule_ids) > 0:
                rule = "\\n".join(self.rule2text.get(rule_id, "") for rule_id in rule_ids)
            else:
                rule = ""
            gloss(verbose, inp, _inp, rule)
        for func in (link1, link2, link3, link4):
            inp = func(inp, descriptive, verbose)
        if group_vowels:
            inp = group(inp)
        if to_syl:
            inp = compose(inp)
        return inp

if __name__ == "__main__":
    g2p = G2p()
    g2p("\\ub098\\uc758 \\uce5c\\uad6c\\uac00 mp3 file 3\\uac1c\\ub97c \\ub2e4\\uc6b4\\ubc1b\\uace0 \\uc788\\ub2e4")
''')
    print("  Wrote complete patched g2pkk/g2pkk.py (MeCab.Tagger + mecab-ko-dic)")
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
