vim9script

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
execute 'source ' .. fnameescape(ROOT .. '/plugin/simpleeditorconfig.vim')

def WaitFor(Cond: func(): bool, timeout: number = 3000): bool
  var waited = 0
  while !Cond() && waited < timeout
    sleep 10m
    waited += 10
  endwhile
  return Cond()
enddef

const BASE = tempname()
mkdir(BASE .. '/src/nested', 'p')
writefile([
  'root = true',
  '',
  '[*]',
  'indent_style = space',
  'indent_size = 4',
  'trim_trailing_whitespace = true',
  'insert_final_newline = true',
  '',
  '[*.py]',
  'indent_size = 2',
  'max_line_length = 88',
], BASE .. '/.editorconfig')
writefile([
  '[*.py]',
  'indent_size = 3',
], BASE .. '/src/.editorconfig')
writefile(['print("ok")  '], BASE .. '/src/nested/main.py')

execute 'edit ' .. fnameescape(BASE .. '/src/nested/main.py')
simpleeditorconfig#Apply(bufnr())
assert_true(&l:expandtab)
assert_equal(3, &l:shiftwidth)
assert_equal(3, &l:softtabstop)
assert_equal(88, &l:textwidth)
assert_equal(2, len(b:simpleeditorconfig_sources))
simpleeditorconfig#BeforeWrite()
assert_equal('print("ok")', getline(1))

# ---------------------------------------------------------------------------
# Virtual-mode remote:// buffers.  g:SimpleRemoteReadFile is stubbed the way
# SimpleRemote answers: (ok, body) with the agent's `not a file: <path>` for a
# missing file, or a synchronous failure and -1 when no workspace is ready.
# The stub answers on the spot unless g:remote_async asks for a timer, so both
# the synchronous and the asynchronous shape of the callback are exercised.
g:remote_editorconfigs = {
  '/workspace/.editorconfig': join([
    'root = true', '[*]', 'indent_style = tab', 'tab_width = 8',
    'trim_trailing_whitespace = true',
  ], "\n"),
  '/workspace/src/.editorconfig': join([
    '[*.py]', 'indent_style = space', 'indent_size = 2',
  ], "\n"),
}
g:remote_editorconfig_reads = []
g:remote_async = false
g:remote_fail = {}
g:remote_refuse = false
def g:SimpleRemoteReadFile(path: string, Callback: func): number
  add(g:remote_editorconfig_reads, path)
  if g:remote_refuse
    call(Callback, [false, 'remote workspace is not ready'])
    return -1
  endif
  var ok = !!has_key(g:remote_editorconfigs, path)
  var body = ok ? g:remote_editorconfigs[path] : 'not a file: ' .. path
  if has_key(g:remote_fail, path)
    ok = false
    body = g:remote_fail[path]
  endif
  if g:remote_async
    timer_start(5, (_) => call(Callback, [ok, body]))
  else
    call(Callback, [ok, body])
  endif
  return 1
enddef
def g:SimpleRemoteStatusline(): string
  return 'ssh:devbox:workspace@12ms'
enddef

def RemoteBuffer(path: string, ftype: string = 'python'): number
  enew!
  setlocal buftype=acwrite
  execute 'setlocal filetype=' .. ftype
  execute 'silent file remote://' .. path
  b:vimrc_remote = {path: path, uri: 'remote://' .. path, generation: 1}
  return bufnr()
enddef

def FireBufferRead(buf: number)
  g:simpleremote_event = {event: 'SimpleRemoteBufferRead', type: 'buffer-read',
    bufnr: buf, path: getbufvar(buf, 'vimrc_remote').path,
    workspace: copy(g:simpleremote_workspace), status: 'ssh:devbox',
    time: localtime()}
  doautocmd <nomodeline> User SimpleRemoteBufferRead
enddef

def Fire(event: string, payload: dict<any>)
  g:simpleremote_event = extend(copy(payload),
    {event: event, status: 'ssh:devbox', time: localtime()})
  execute 'doautocmd <nomodeline> User ' .. event
enddef

g:simpleremote_workspace = {id: 1, kind: 'ssh', target: 'devbox',
  root: '/workspace', tree_root: '/workspace', local_root: '', mode: 'virtual'}
RemoteBuffer('/workspace/src/lib/main.py')
FireBufferRead(bufnr())
assert_true(&l:expandtab)
assert_equal(2, &l:shiftwidth)
assert_equal(8, &l:tabstop)
assert_equal([
  '/workspace/.editorconfig', '/workspace/src/.editorconfig',
], b:simpleeditorconfig_sources)
# Every candidate directory is asked at once, the file's own first, the
# workspace root last, and nothing above the root.
assert_equal([
  '/workspace/src/lib/.editorconfig',
  '/workspace/src/.editorconfig',
  '/workspace/.editorconfig',
], g:remote_editorconfig_reads)

# SimpleRemote fires BufWritePre from its BufWriteCmd, so a remote save runs
# BeforeWrite() like a local one: trim_trailing_whitespace must reach the
# acwrite buffer through the autocmd, not only through a direct call.
setline(1, ['import os   ', 'print(os.name)  '])
doautocmd <nomodeline> BufWritePre
assert_equal(['import os', 'print(os.name)'], getline(1, '$'))
setlocal nomodified

# A second buffer in the same directory is answered from the cache: no reads.
var reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/other.py')
FireBufferRead(bufnr())
assert_equal(reads_before, len(g:remote_editorconfig_reads),
  'cached remote .editorconfig files must not be read again')
assert_equal(2, &l:shiftwidth)
assert_equal([
  '/workspace/.editorconfig', '/workspace/src/.editorconfig',
], b:simpleeditorconfig_sources)

# A deeper file reuses the cached parents and reads only what is new.
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/deep/x.py')
FireBufferRead(bufnr())
assert_equal(['/workspace/src/lib/deep/.editorconfig'],
  g:remote_editorconfig_reads[reads_before :])
assert_equal(2, &l:shiftwidth)

# A lexical prefix is not a workspace child: /workspace2 must never inherit
# /workspace configuration or trigger remote reads for the active workspace.
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace2/src/main.py')
setlocal shiftwidth=6
simpleeditorconfig#Apply(bufnr())
assert_equal(reads_before, len(g:remote_editorconfig_reads))
assert_equal(6, &l:shiftwidth)

# Saving a .editorconfig from a remote:// buffer makes the cached copy stale:
# BufWritePost drops it and the next buffer sees the new contents.
g:remote_editorconfigs['/workspace/src/.editorconfig'] = join([
  '[*.py]', 'indent_style = space', 'indent_size = 3',
], "\n")
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/stale.py')
FireBufferRead(bufnr())
assert_equal(2, &l:shiftwidth, 'the cache is still authoritative until told otherwise')
assert_equal(reads_before, len(g:remote_editorconfig_reads))
RemoteBuffer('/workspace/src/.editorconfig', 'editorconfig')
setline(1, split(g:remote_editorconfigs['/workspace/src/.editorconfig'], "\n"))
setlocal nomodified
doautocmd <nomodeline> BufWritePost
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/fresh.py')
FireBufferRead(bufnr())
assert_equal(3, &l:shiftwidth, 'a saved .editorconfig must be re-read')
assert_true(len(g:remote_editorconfig_reads) > reads_before)

# SimpleRemoteFilesChanged: a change that cannot have touched a .editorconfig
# costs nothing; one naming a .editorconfig, or a directory holding one, drops
# what may be stale.
reads_before = len(g:remote_editorconfig_reads)
Fire('SimpleRemoteFilesChanged', {changes: [
  {path: '/workspace/src/lib/main.py', type: 'changed'}],
  workspace: copy(g:simpleremote_workspace)})
RemoteBuffer('/workspace/src/lib/a.py')
FireBufferRead(bufnr())
assert_equal(reads_before, len(g:remote_editorconfig_reads),
  'an unrelated change must not empty the cache')
Fire('SimpleRemoteFilesChanged', {changes: [
  {path: '/workspace/src', type: 'deleted'}],
  workspace: copy(g:simpleremote_workspace)})
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/b.py')
FireBufferRead(bufnr())
assert_equal([
  '/workspace/src/lib/.editorconfig', '/workspace/src/.editorconfig',
], g:remote_editorconfig_reads[reads_before :],
  'a deleted directory drops the entries under it and keeps the root')
Fire('SimpleRemoteFilesChanged', {changes: [
  {path: '/workspace/.editorconfig', type: 'created'}],
  workspace: copy(g:simpleremote_workspace)})
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/c.py')
FireBufferRead(bufnr())
assert_equal(3, len(g:remote_editorconfig_reads) - reads_before,
  'a created .editorconfig drops the whole cache')

# SimpleRemoteWorkspaceChanged and SimpleRemoteDisconnected empty the cache.
Fire('SimpleRemoteWorkspaceChanged', {snapshot: copy(g:simpleremote_workspace)})
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/d.py')
FireBufferRead(bufnr())
assert_equal(3, len(g:remote_editorconfig_reads) - reads_before)
Fire('SimpleRemoteDisconnected', {reason: 'reconnect'})
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/e.py')
FireBufferRead(bufnr())
assert_equal(3, len(g:remote_editorconfig_reads) - reads_before)

# :SimpleEditorConfigReload is the user asking for a fresh read.
reads_before = len(g:remote_editorconfig_reads)
SimpleEditorConfigReload
assert_equal(3, len(g:remote_editorconfig_reads) - reads_before)
assert_equal(3, &l:shiftwidth)

# The walk is cut at the first `root = true`, whatever was read above it.
g:remote_editorconfigs['/workspace/src/.editorconfig'] = join([
  'root = true', '[*.py]', 'indent_style = space', 'indent_size = 5',
], "\n")
simpleeditorconfig#ForgetRemote()
RemoteBuffer('/workspace/src/lib/rooted.py')
FireBufferRead(bufnr())
assert_equal(['/workspace/src/.editorconfig'], b:simpleeditorconfig_sources)
assert_equal(5, &l:shiftwidth)
assert_equal(5, &l:tabstop, 'tab_width above the root must not apply')
g:remote_editorconfigs['/workspace/src/.editorconfig'] = join([
  '[*.py]', 'indent_style = space', 'indent_size = 3',
], "\n")

# A transport failure above the first `root = true` is a failure to read a
# file the walk was going to throw away: the part that decides this buffer is
# complete, so it applies.  The old sequential walk stopped at the root marker
# and never asked that directory at all.
simpleeditorconfig#ForgetRemote()
g:remote_editorconfigs['/workspace/src/.editorconfig'] = join([
  'root = true', '[*.py]', 'indent_style = space', 'indent_size = 5',
], "\n")
g:remote_fail = {'/workspace/.editorconfig': 'connection closed'}
RemoteBuffer('/workspace/src/lib/rooted_broken.py')
setlocal shiftwidth=7 noexpandtab
FireBufferRead(bufnr())
assert_equal(['/workspace/src/.editorconfig'],
  get(b:, 'simpleeditorconfig_sources', []),
  'a failure above the root cut must not discard the walk')
assert_equal(5, &l:shiftwidth)
assert_true(&l:expandtab)
# What answered is cached and what failed is not, so the next buffer in the
# same directory asks for the failed directory alone.
g:remote_fail = {}
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/reasked.py')
FireBufferRead(bufnr())
assert_equal(['/workspace/.editorconfig'],
  g:remote_editorconfig_reads[reads_before :],
  'a failed read must not be cached, and an answered one must not be re-read')
assert_equal(5, &l:shiftwidth)
g:remote_editorconfigs['/workspace/src/.editorconfig'] = join([
  '[*.py]', 'indent_style = space', 'indent_size = 3',
], "\n")

# A transport failure inside the range the cut keeps is not "no
# .editorconfig": a walk that did not see the whole picture applies nothing
# rather than a partial, incoherent set.
simpleeditorconfig#ForgetRemote()
g:remote_fail = {'/workspace/.editorconfig': 'connection closed'}
RemoteBuffer('/workspace/src/lib/broken.py')
setlocal shiftwidth=7 noexpandtab
FireBufferRead(bufnr())
assert_equal(7, &l:shiftwidth, 'a failed walk must leave the buffer alone')
assert_false(&l:expandtab)
assert_equal([], get(b:, 'simpleeditorconfig_sources', []))
g:remote_fail = {}
# ... and a read that cannot even be issued (no workspace ready) does the same.
g:remote_refuse = true
RemoteBuffer('/workspace/src/lib/refused.py')
setlocal shiftwidth=7 noexpandtab
FireBufferRead(bufnr())
assert_equal(7, &l:shiftwidth)
assert_equal([], get(b:, 'simpleeditorconfig_sources', []))
g:remote_refuse = false
# A failure did not poison the cache: the next buffer walks and applies.
RemoteBuffer('/workspace/src/lib/after.py')
FireBufferRead(bufnr())
assert_equal(3, &l:shiftwidth)
assert_equal([
  '/workspace/.editorconfig', '/workspace/src/.editorconfig',
], b:simpleeditorconfig_sources)

# Asynchronous answers: the options land once every directory has replied,
# and a re-read that starts while a walk is in flight supersedes it — the
# earlier answers must not overwrite the later ones.
simpleeditorconfig#ForgetRemote()
g:remote_async = true
var abuf = RemoteBuffer('/workspace/src/lib/async.py')
setlocal shiftwidth=7
FireBufferRead(abuf)
assert_equal(7, &l:shiftwidth, 'nothing applies before the answers arrive')
assert_true(WaitFor(() => getbufvar(abuf, '&shiftwidth') == 3))
assert_equal([
  '/workspace/.editorconfig', '/workspace/src/.editorconfig',
], b:simpleeditorconfig_sources)
simpleeditorconfig#ForgetRemote()
var sbuf = RemoteBuffer('/workspace/src/lib/super.py')
setlocal shiftwidth=7
FireBufferRead(sbuf)
# The first walk captured indent_size = 3; the second, started before any
# answer arrived, sees indent_size = 4 and must be the one that wins.
g:remote_editorconfigs['/workspace/src/.editorconfig'] = join([
  '[*.py]', 'indent_style = space', 'indent_size = 4',
], "\n")
FireBufferRead(sbuf)
assert_true(WaitFor(() => getbufvar(sbuf, '&shiftwidth') != 7))
sleep 50m
assert_equal(4, getbufvar(sbuf, '&shiftwidth'),
  'a superseded walk must not apply its answers')

# An invalidation that lands while a walk is on the wire must not be undone by
# that walk's late answers: they carry what the file said before the change,
# they may still configure the buffer that asked for them, and they must never
# reach the cache, where every buffer opened afterwards would read them.
g:remote_editorconfigs['/workspace/src/.editorconfig'] = join([
  '[*.py]', 'indent_style = space', 'indent_size = 3',
], "\n")
simpleeditorconfig#ForgetRemote()
reads_before = len(g:remote_editorconfig_reads)
var rbuf = RemoteBuffer('/workspace/src/lib/race.py')
setlocal shiftwidth=7
FireBufferRead(rbuf)
assert_equal(3, len(g:remote_editorconfig_reads) - reads_before,
  'the reads must be on the wire when the change lands')
# They are; the file changes remotely now, before any of them answers.
g:remote_editorconfigs['/workspace/src/.editorconfig'] = join([
  '[*.py]', 'indent_style = space', 'indent_size = 6',
], "\n")
Fire('SimpleRemoteFilesChanged', {changes: [
  {path: '/workspace/src/.editorconfig', type: 'changed'}],
  workspace: copy(g:simpleremote_workspace)})
assert_true(WaitFor(() => getbufvar(rbuf, '&shiftwidth') != 7))
assert_equal(3, getbufvar(rbuf, '&shiftwidth'),
  'the buffer applies the answers it asked for')
sleep 20m
g:remote_async = false
reads_before = len(g:remote_editorconfig_reads)
RemoteBuffer('/workspace/src/lib/after_race.py')
FireBufferRead(bufnr())
assert_equal(3, len(g:remote_editorconfig_reads) - reads_before,
  'answers that raced an invalidation must not be cached')
assert_equal(6, &l:shiftwidth, 'the next buffer must see the new file')
g:remote_editorconfigs['/workspace/src/.editorconfig'] = join([
  '[*.py]', 'indent_style = space', 'indent_size = 3',
], "\n")
simpleeditorconfig#ForgetRemote()

# The same holds for the events that empty the whole cache — a workspace
# swapped for another, a disconnect, :SimpleEditorConfigReload: a walk that
# was in flight must not re-fill what they threw away.
g:remote_async = true
reads_before = len(g:remote_editorconfig_reads)
var wbuf = RemoteBuffer('/workspace/src/lib/swapped.py')
setlocal shiftwidth=7
FireBufferRead(wbuf)
assert_equal(3, len(g:remote_editorconfig_reads) - reads_before,
  'the reads must be on the wire when the workspace changes')
Fire('SimpleRemoteWorkspaceChanged', {snapshot: copy(g:simpleremote_workspace)})
assert_true(WaitFor(() => getbufvar(wbuf, '&shiftwidth') == 3))
sleep 20m
assert_match('remote cache: 0 file(s)',
  execute('call simpleeditorconfig#Health()'),
  'answers from before the invalidation must stay out of the cache')
g:remote_async = false

# Info and Health name the workspace.
var info = execute('call simpleeditorconfig#Info()')
assert_match('workspace: ssh:devbox:workspace@12ms mode=virtual buffer=remote', info)
var health = execute('call simpleeditorconfig#Health()')
assert_match('remote reads: available', health)
assert_match('workspace: ssh:devbox:workspace@12ms mode=virtual', health)
assert_match('remote cache: \d\+ file(s)', health)

# ---------------------------------------------------------------------------
# An sshfs workspace is a mount SimpleRemote made of the remote root under
# ~/.local/state/vim/simpleremote/mounts, so the walk stops there: what sits
# above the mount point on this machine is not part of the project.
const MOUNT = tempname()
mkdir(MOUNT .. '/proj/src', 'p')
writefile([
  'root = true', '[*]', 'indent_style = space', 'indent_size = 9',
  'max_line_length = 120',
], MOUNT .. '/.editorconfig')
writefile([
  '[*]', 'indent_style = space', 'indent_size = 4',
], MOUNT .. '/proj/.editorconfig')
writefile(['x = 1'], MOUNT .. '/proj/src/a.py')
writefile(['y = 1'], MOUNT .. '/other.py')
const RESOLVED = resolve(MOUNT)
g:simpleremote_workspace = {id: 2, kind: 'ssh', target: 'devbox',
  root: '/srv/app', tree_root: '/srv/app', local_root: MOUNT .. '/proj/',
  mode: 'sshfs'}
execute 'edit ' .. fnameescape(MOUNT .. '/proj/src/a.py')
simpleeditorconfig#Apply(bufnr())
assert_equal([RESOLVED .. '/proj/.editorconfig'], b:simpleeditorconfig_sources,
  'a projected buffer must not read above the mount point')
assert_equal(4, &l:shiftwidth)
assert_equal(0, &l:textwidth)
info = execute('call simpleeditorconfig#Info()')
assert_match('mode=sshfs buffer=projected', info)
# A local file outside the projection walks as it always did.
execute 'edit ' .. fnameescape(MOUNT .. '/other.py')
simpleeditorconfig#Apply(bufnr())
assert_equal([RESOLVED .. '/.editorconfig'], b:simpleeditorconfig_sources)
assert_equal(9, &l:shiftwidth)
info = execute('call simpleeditorconfig#Info()')
assert_match('mode=sshfs buffer=local', info)
# local-map is a directory the user chose here; it inherits its surroundings.
g:simpleremote_workspace.mode = 'local-map'
execute 'edit ' .. fnameescape(MOUNT .. '/proj/src/a.py')
simpleeditorconfig#Apply(bufnr())
assert_equal([RESOLVED .. '/.editorconfig', RESOLVED .. '/proj/.editorconfig'],
  b:simpleeditorconfig_sources)
assert_equal(120, &l:textwidth)
# docker-bind is the host side of a bind mount — g:simpleremote_local_roots or
# the Source of the container's mount, either way a checkout the user keeps in
# their own tree.  Connecting a container must not change what an ordinary
# local buffer in it gets, so it inherits its surroundings like local-map.
g:simpleremote_workspace.mode = 'docker-bind'
simpleeditorconfig#Apply(bufnr())
assert_equal([RESOLVED .. '/.editorconfig', RESOLVED .. '/proj/.editorconfig'],
  b:simpleeditorconfig_sources,
  'a docker-bind checkout must keep inheriting from above the bind point')
assert_equal(120, &l:textwidth)
# It is still a projection, and Info() says so.
info = execute('call simpleeditorconfig#Info()')
assert_match('mode=docker-bind buffer=projected', info)
# Without a workspace the same buffer is an ordinary local file again.
unlet g:simpleremote_workspace
simpleeditorconfig#Apply(bufnr())
assert_equal(2, len(b:simpleeditorconfig_sources))
delete(MOUNT, 'rf')

# `unset` takes back a value an earlier section gave, and a .editorconfig is
# entitled to unset a key that nothing above it ever set.  Removing an absent
# key is E716, which used to be thrown out of Apply() on the BufReadPost path
# and cost the buffer every other property in the file, not only the unset one.
mkdir(BASE .. '/unset', 'p')
writefile([
  'root = true',
  '[*]',
  'indent_style = space',
  'indent_size = 4',
  '',
  '[*.md]',
  'indent_size = unset',
  'max_line_length = unset',
  'tab_width = 2',
], BASE .. '/unset/.editorconfig')
writefile(['# heading'], BASE .. '/unset/notes.md')
execute 'edit ' .. fnameescape(BASE .. '/unset/notes.md')
simpleeditorconfig#Apply(bufnr())
assert_false(has_key(b:simpleeditorconfig, 'indent_size'),
  'an unset key must be removed')
assert_false(has_key(b:simpleeditorconfig, 'max_line_length'),
  'unsetting a key nothing ever set must not abort the rest of the section')
assert_equal('2', b:simpleeditorconfig.tab_width)
assert_equal('space', b:simpleeditorconfig.indent_style)

assert_equal(2, exists(':SimpleEditorConfigReload'))
delete(BASE, 'rf')
if !empty(v:errors)
  writefile(v:errors, ROOT .. '/tests/errors.log')
  cquit
endif
qa!
