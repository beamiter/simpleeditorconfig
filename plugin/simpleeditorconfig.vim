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

command! SimpleEditorConfigReload simpleeditorconfig#Apply(bufnr())
command! SimpleEditorConfigInfo simpleeditorconfig#Info()
command! SimpleEditorConfigHealth simpleeditorconfig#Health()

augroup SimpleEditorConfig
  autocmd!
  autocmd BufReadPost,BufNewFile * simpleeditorconfig#Apply(bufnr())
  autocmd User SimpleRemoteBufferRead simpleeditorconfig#ApplyRemoteEvent()
  autocmd BufWritePre * simpleeditorconfig#BeforeWrite()
augroup END
