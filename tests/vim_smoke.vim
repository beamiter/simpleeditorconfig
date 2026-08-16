vim9script

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
execute 'source ' .. fnameescape(ROOT .. '/plugin/simpleeditorconfig.vim')

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

g:remote_editorconfigs = {
  '/workspace/.editorconfig': join([
    'root = true', '[*]', 'indent_style = tab', 'tab_width = 8',
  ], "\n"),
  '/workspace/src/.editorconfig': join([
    '[*.py]', 'indent_style = space', 'indent_size = 2',
  ], "\n"),
}
g:remote_editorconfig_reads = []
def g:SimpleRemoteReadFile(path: string, Callback: func): number
  add(g:remote_editorconfig_reads, path)
  if has_key(g:remote_editorconfigs, path)
    call(Callback, [true, g:remote_editorconfigs[path]])
  else
    call(Callback, [false, 'not found'])
  endif
  return 1
enddef
g:simpleremote_workspace = {root: '/workspace'}
enew!
setlocal buftype=acwrite filetype=python
silent file remote:///workspace/src/lib/main.py
b:vimrc_remote = {path: '/workspace/src/lib/main.py'}
g:simpleremote_event = {type: 'buffer-read', bufnr: bufnr(),
  path: b:vimrc_remote.path, workspace: copy(g:simpleremote_workspace)}
doautocmd <nomodeline> User SimpleRemoteBufferRead
assert_true(&l:expandtab)
assert_equal(2, &l:shiftwidth)
assert_equal(8, &l:tabstop)
assert_equal([
  '/workspace/.editorconfig', '/workspace/src/.editorconfig',
], b:simpleeditorconfig_sources)

# A lexical prefix is not a workspace child: /workspace2 must never inherit
# /workspace configuration or trigger remote reads for the active workspace.
var reads_before = len(g:remote_editorconfig_reads)
enew!
setlocal buftype=acwrite filetype=python shiftwidth=6
silent file remote:///workspace2/src/main.py
b:vimrc_remote = {path: '/workspace2/src/main.py'}
simpleeditorconfig#Apply(bufnr())
assert_equal(reads_before, len(g:remote_editorconfig_reads))
assert_equal(6, &l:shiftwidth)

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
