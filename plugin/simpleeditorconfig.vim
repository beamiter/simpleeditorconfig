vim9script

if exists('g:loaded_simpleeditorconfig')
  finish
endif
g:loaded_simpleeditorconfig = 1

if v:version < 901
  echohl WarningMsg
  echomsg '[SimpleEditorConfig] Vim 9.1 or newer is required.'
  echohl None
  finish
endif

g:simpleeditorconfig_enable = get(g:, 'simpleeditorconfig_enable', 1)
g:simpleeditorconfig_remote = get(g:, 'simpleeditorconfig_remote', 1)
g:simpleeditorconfig_verbose = get(g:, 'simpleeditorconfig_verbose', 0)

command! SimpleEditorConfigReload simpleeditorconfig#Reload(bufnr())
command! SimpleEditorConfigInfo simpleeditorconfig#Info()
command! SimpleEditorConfigHealth simpleeditorconfig#Health()

augroup SimpleEditorConfig
  autocmd!
  autocmd BufReadPre * simpleeditorconfig#BeforeRead(bufnr())
  autocmd BufReadPost * simpleeditorconfig#AfterRead(bufnr())
  # A failed read may not emit BufReadPost.  The generation-bound fallback
  # timer is the primary cleanup; leaving or unloading the failed buffer gives
  # it an additional synchronous recovery path.
  autocmd BufEnter,BufLeave,BufUnload * simpleeditorconfig#RestoreReadEncoding(str2nr(expand('<abuf>')))
  autocmd BufNewFile * simpleeditorconfig#Apply(bufnr())
  autocmd BufWritePre * simpleeditorconfig#BeforeWrite()
  autocmd BufWritePost * simpleeditorconfig#AfterWrite()
  # SimpleRemote fills remote:// buffers through a BufReadCmd, which
  # suppresses BufReadPost; this is the event that reaches us for them.  The
  # rest keeps the cache of remote .editorconfig files honest.  All of these
  # are harmless when SimpleRemote is not installed: nothing fires them.
  autocmd User SimpleRemoteBufferRead simpleeditorconfig#ApplyRemoteEvent()
  autocmd User SimpleRemoteFilesChanged simpleeditorconfig#OnRemoteFilesChanged()
  autocmd User SimpleRemoteWorkspaceChanged simpleeditorconfig#ForgetRemote()
  autocmd User SimpleRemoteDisconnected simpleeditorconfig#ForgetRemote()
augroup END
