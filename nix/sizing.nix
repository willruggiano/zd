{
  runCommand,
  python3,
  package,
  small,
}:
runCommand "dictation-storage-sizing" { nativeBuildInputs = [ python3 ]; } ''
  ${package}/bin/dictation footprint > default
  ${small}/bin/dictation footprint > small
  python3 - <<'PY'
  def read(path):
      return {k: int(v) for k, v in (line.split('=') for line in open(path))}
  large, small = read('default'), read('small')
  assert large['transcript_bytes'] == 1048576
  assert small['transcript_bytes'] == 64
  assert small['clipboard_slots'] == 2
  assert small['control_clients'] == 2
  assert small['transfers'] == 1
  assert small['static_bytes'] < 4096
  assert large['static_bytes'] > 4 * 1048576
  assert large['wayland_backing_bytes'] == small['wayland_backing_bytes'] == 51200
  assert large['static_bytes'] % large['alignment'] == 0
  PY
  mkdir "$out"
  cp default small "$out/"
''
