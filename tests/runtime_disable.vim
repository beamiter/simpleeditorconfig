vim9script
set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
runtime plugin/simpleeditorconfig.vim
const BASE = tempname()
mkdir(BASE, 'p')
writefile(['root = true', '[*]', 'indent_size = 3',
  'trim_trailing_whitespace = true'], BASE .. '/.editorconfig')
writefile(['payload'], BASE .. '/file.txt')
execute 'edit ' .. fnameescape(BASE .. '/file.txt')
assert_equal(3, &l:shiftwidth)
for disabled in [0, false]
  setline(1, 'keep spaces  ')
  g:simpleeditorconfig_enable = disabled
  write
  assert_equal(['keep spaces  '], readfile(BASE .. '/file.txt'),
    'disabled plugin stripped whitespace while saving')
  assert_equal(3, &l:shiftwidth, 'disable must not reset existing buffer options')
  g:simpleeditorconfig_enable = 1
  write
  assert_equal(['keep spaces'], readfile(BASE .. '/file.txt'),
    're-enabled plugin did not resume whitespace trimming')
endfor

# Hold real remote-reader callbacks to prove turning a flag off also blocks
# work that was already requested. No second Apply() is needed to disable it.
g:pending_reads = []
def g:SimpleRemoteReadFile(_path: string, Callback: func): number
  add(g:pending_reads, Callback)
  return 1
enddef
g:simpleremote_workspace = {root: '/workspace', id: 1, mode: 'virtual'}
for flag in ['simpleeditorconfig_enable', 'simpleeditorconfig_remote']
  for disabled in [0, false]
    simpleeditorconfig#ForgetRemote()
    enew!
    setlocal buftype=acwrite shiftwidth=7
    b:vimrc_remote = {path: '/workspace/file.txt'}
    simpleeditorconfig#Apply()
    assert_equal(1, len(g:pending_reads), 'fixture did not defer a remote read')
    g:[flag] = disabled
    for Callback in g:pending_reads
      call(Callback, [true, "root = true\n[*]\nindent_size = 2"])
    endfor
    g:pending_reads = []
    assert_equal(7, &l:shiftwidth, 'late remote reply ignored ' .. flag)
    assert_equal({}, get(b:, 'simpleeditorconfig', {}),
      'disabled reply published configuration')
    g:[flag] = 1
    simpleeditorconfig#Reload()
    assert_equal(1, len(g:pending_reads))
    for Callback in g:pending_reads
      call(Callback, [true, "root = true\n[*]\nindent_size = 2"])
    endfor
    g:pending_reads = []
    assert_equal(2, &l:shiftwidth, 're-enable and reload did not apply')
  endfor
endfor
delete(BASE, 'rf')
if !empty(v:errors)
  writefile(v:errors, ROOT .. '/tests/runtime_disable_errors.log')
  cquit 1
endif
qa!
