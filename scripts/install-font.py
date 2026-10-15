#!/usr/bin/env python3
"""Install the unmodified Chillax Light face from the user's Fontshare archive."""
import os
from pathlib import Path
import subprocess
import sys
import zipfile

archive = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / 'Downloads/Chillax_Complete.zip'
font_home = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'fonts/Chillax'
font_home.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(archive) as source:
    for member in ['Chillax_Complete/Fonts/OTF/Chillax-Light.otf', 'Chillax_Complete/License/FFL.txt']:
        (font_home / Path(member).name).write_bytes(source.read(member))
subprocess.run(['fc-cache', '-f', str(font_home)], check=True)
print('Installed Chillax Light in', font_home)
