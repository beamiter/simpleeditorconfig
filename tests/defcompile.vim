" Force-compile every :def in this plugin's autoload scripts.
"
" Vim9 compiles def bodies lazily, so a syntax or type error in a branch no
" test reaches stays invisible until a user happens to reach it — and then it
" fails inside whatever autocmd or mapping called it.  :defcompile forces the
" whole script through the compiler here instead.
"
" The obvious spelling of that does nothing at all, which is how this gate sat
" green over a real type error for as long as it has existed:
"
"     source autoload/<plugin>.vim
"     defcompile
"
" :defcompile compiles the functions of the script it is *executed in*, and
" that is this file — the sourced script's defs belong to a different script
" context and are never touched.  So each autoload script is copied to a temp
" file with a trailing :defcompile appended, and the copy is sourced: the
" compile then runs inside the script that owns the functions.  Sourcing the
" original again would not do, because a script already loaded under its own
" name is a no-op for anything that guards against reloading.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
"
" A script that cannot survive being sourced under another name — an autoload
" script whose functions are named for their own path, which Vim checks — can
" be excluded by listing basename globs, one per line, in
" tests/defcompile-skip.  Skipping means the script is not compile-checked at
" all, so it is for scripts that are data rather than logic.

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/defcompile-errors.log')

" The autoload scripts read configuration whose defaults the plugin file
" installs, so load that first — otherwise every g: lookup is undefined.
for s:p in glob(s:root .. '/plugin/**/*.vim', 0, 1)
  try
    execute 'source ' .. fnameescape(s:p)
  catch
    " A plugin file that refuses to load is the smoke test's problem, not this
    " one's; keep going so the compile results still get reported.
  endtry
endfor

let s:skip = []
let s:skipfile = s:root .. '/tests/defcompile-skip'
if filereadable(s:skipfile)
  " Comments and blank lines are ignored so the file can explain itself.
  let s:skip = filter(map(readfile(s:skipfile), {_, v -> trim(v)}),
        \ {_, v -> v !=# '' && v[0] !=# '#'})
endif

let s:errors = []
for s:f in glob(s:root .. '/autoload/**/*.vim', 0, 1)
  let s:base = fnamemodify(s:f, ':t')
  let s:skipped = 0
  for s:pat in s:skip
    if s:base =~# glob2regpat(s:pat)
      let s:skipped = 1
      break
    endif
  endfor
  if s:skipped
    continue
  endif

  let s:tmp = tempname() .. '.vim'
  call writefile(readfile(s:f) + ['defcompile'], s:tmp)
  try
    execute 'source ' .. fnameescape(s:tmp)
  catch
    call add(s:errors, fnamemodify(s:f, ':t') .. ': ' .. v:exception)
  endtry
  call delete(s:tmp)
endfor

if len(s:errors)
  for s:e in s:errors
    echomsg s:e
  endfor
  call writefile(s:errors, s:root .. '/tests/defcompile-errors.log')
  cquit
endif
qall!
