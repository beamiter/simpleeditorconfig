.PHONY: check defcompile test glob

check: defcompile test glob

defcompile:
	vim -N -u NONE -n -es -S tests/defcompile.vim

test:
	vim -N -u NONE -n -es -S tests/vim_smoke.vim

glob:
	vim -N -u NONE -n -es -S tests/glob.vim
