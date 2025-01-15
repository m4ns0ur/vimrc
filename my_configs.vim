set nocompatible
set number relativenumber
set showcmd
set nowritebackup
set splitright
set splitbelow
set autowrite
set fileformats=unix,dos,mac
set noshowmode
set ttyfast
set nocursorcolumn
set cursorline
set autoindent

set notimeout
set ttimeout
set ttimeoutlen=10

syntax sync minlines=256
set synmaxcol=300
set re=1

au FocusLost * :wa

nnoremap <leader><space> :nohlsearch<CR>
nnoremap <space> zz
nnoremap <Leader>c :set cursorline!<CR>

nnoremap n nzzzv
nnoremap N Nzzzv

map <Up> gk
map <Down> gj
map k gk
map j gj

" Different cursor shape per mode
let &t_SI = "\<Esc>[5 q"
let &t_SR = "\<Esc>[3 q"
let &t_EI = "\<Esc>[1 q"

let &t_SI .= "\<Esc>[?2004h"
let &t_EI .= "\<Esc>[?2004l"

set background=dark
"let g:solarized_termcolors=256
"colorscheme solarized
let g:onedark_termcolors=256
colorscheme onedark

" If linux then set ttymouse
let s:uname = system("echo -n \"$(uname)\"")
if !v:shell_error && s:uname == "Linux" && !has('nvim')
    set ttymouse=xterm
endif

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" vim-go
" by: https://github.com/jessfraz/.vim/blob/master/vimrc
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
let g:go_fmt_fail_silently = 0
let g:go_fmt_command = "goimports"
let g:go_autodetect_gopath = 1
let g:go_term_enabled = 1
let g:go_snippet_engine = "neosnippet"
let g:go_highlight_space_tab_error = 0
let g:go_highlight_array_whitespace_error = 0
let g:go_highlight_trailing_whitespace_error = 0
let g:go_highlight_extra_types = 0
let g:go_highlight_operators = 0
let g:go_highlight_build_constraints = 1
let g:go_fmt_autosave = 1

au FileType go nmap <Leader>s <Plug>(go-def-split)
au FileType go nmap <Leader>v <Plug>(go-def-vertical)
au FileType go nmap <Leader>i <Plug>(go-info)
au FileType go nmap <Leader>l <Plug>(go-metalinter)

au FileType go nmap <leader>r  <Plug>(go-run)

au FileType go nmap <leader>b  <Plug>(go-build)
au FileType go nmap <leader>t  <Plug>(go-test)
au FileType go nmap <leader>dt  <Plug>(go-test-compile)
au FileType go nmap <Leader>d <Plug>(go-doc)

au FileType go nmap <Leader>e <Plug>(go-rename)

" neovim specific
if has('nvim')
  au FileType go nmap <leader>rt <Plug>(go-run-tab)
  au FileType go nmap <Leader>rs <Plug>(go-run-split)
  au FileType go nmap <Leader>rv <Plug>(go-run-vertical)
endif

" I like these more!
augroup go
  autocmd!
  autocmd Filetype go command! -bang A call go#alternate#Switch(<bang>0, 'edit')
  autocmd Filetype go command! -bang AV call go#alternate#Switch(<bang>0, 'vsplit')
  autocmd Filetype go command! -bang AS call go#alternate#Switch(<bang>0, 'split')
augroup END

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" comfortable-motions
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
let g:loaded_comfortable_motion = 0
