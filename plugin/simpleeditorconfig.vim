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
  autocmd BufReadPost,BufNewFile * simpleeditorconfig#Apply(bufnr())
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
