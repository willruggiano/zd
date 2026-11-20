"""Installed native indicator; private real PipeWire/Sway, synthetic non-sensitive PCM."""
import io
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
from PIL import Image

binary, pid = sys.argv[1:]
os.environ['SWAYSOCK'] = str(next(Path(os.environ['XDG_RUNTIME_DIR']).glob('sway-ipc.*.sock')))


def run(*args):
    return subprocess.check_output(args, timeout=5)


def eventually(predicate, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.04)
    raise AssertionError('native indicator condition timed out')


def log():
    return Path('daemon.log').read_text()


def screenshot(output):
    return Image.open(io.BytesIO(run('grim', '-o', output, '-'))).convert('RGB')


def bars(output):
    image = screenshot(output)
    # Independent expected location: bottom center, 24 logical px margin, 160x40.
    w, h = image.size
    return image.crop((w//2-80, h-64, w//2+80, h-24))


def lit(output):
    return sum(r > 200 and g > 200 and b > 200 for r, g, b in bars(output).get_flattened_data())


def toggle():
    run(binary, 'toggle')


def sway(command):
    assert all(r['success'] for r in json.loads(run('swaymsg', '-t', 'command', command)))


def source():
    nodes = json.loads(run('pw-dump'))
    return next((n['id'] for n in nodes if n.get('info', {}).get('props', {}).get('node.name') == 'test-mic-a'), None)


eventually(lambda: 'model ready' in log(), 60)
eventually(source)
run('wpctl', 'set-default', str(source()))
time.sleep(.4)  # policy and metadata must precede microphone selection
# Both explicitly selected outputs must have a real noninteractive layer surface.
eventually(lambda: log().count('get_layer_surface(') >= 2)
assert log().count('set_keyboard_interactivity(0)') == 2
assert log().count('set_input_region(') == 2
assert 'wl_region' in log() and '.add(' not in log()
assert run('wl-paste', '--no-newline') == b'Previous clipboard'
toggle()
eventually(lambda: lit('HEADLESS-1') > 0 and lit('HEADLESS-2') > 0)
quiet = lit('HEADLESS-1')
# Finish the silent session, then restart on the explicitly selected source.
toggle()
eventually(lambda: 'no speech' in log())
run('wpctl', 'set-default', str(source()))
time.sleep(.4)  # WirePlumber policy and the daemon's serialized metadata dispatch
toggle()
eventually(lambda: log().count('capture ready') == 2)
nodes = json.loads(run('pw-dump'))
props = {n.get('info', {}).get('props', {}).get('node.name'): n.get('info', {}).get('props', {}) for n in nodes}
assert str(props['dictation.capture']['target.object']) == str(props['test-mic-a']['object.serial'])
with open('tone.raw', 'wb') as f:
    f.write(b''.join(struct.pack('<f', .2 * math.sin(2 * math.pi * 440 * i / 16000)) for i in range(32000)))
player = subprocess.Popen(['pw-cat', '--playback', '--raw', '--rate=16000', '--channels=1',
                           '--format=f32', '--target=test-feed-a', 'tone.raw'], stdout=subprocess.DEVNULL, stderr=open('player.log', 'wb'))
try:
    eventually(lambda: lit('HEADLESS-1') > quiet * 2 and lit('HEADLESS-2') > quiet * 2)
finally:
    assert player.wait(timeout=10) == 0
eventually(lambda: lit('HEADLESS-1') == quiet)

# Reconfigure scale/mode while recording; logical placement stays bottom-centered.
sway('output HEADLESS-2 mode 1024x768 scale 2')
eventually(lambda: screenshot('HEADLESS-2').size == (1024, 768))
image = screenshot('HEADLESS-2')
assert image.getpixel((512, 768-88)) != image.getpixel((0, 0))

# Repeated removal/re-addition must release our mappings/fds and reuse slots.
def mappings():
    return sum('memfd:dictation-indicator' in line for line in Path(f'/proc/{pid}/maps').read_text().splitlines())

def fd_count():
    return len(list(Path(f'/proc/{pid}/fd').iterdir()))

eventually(lambda: mappings() == 2)
fds = fd_count()
for _ in range(5):
    sway('output HEADLESS-2 disable')
    eventually(lambda: mappings() == 1)
    sway('output HEADLESS-2 enable mode 800x600 scale 1')
    eventually(lambda: mappings() == 2 and lit('HEADLESS-2') == quiet)
    assert fd_count() == fds
    assert run('wl-paste', '--no-newline') == b'Previous clipboard'

# Explicit exhaustion, not silent partial coverage. The named package has two slots.
sway('create_output')
eventually(lambda: 'OutputCapacity' in log())
assert 'copied' not in log()
