.PHONY: check defcompile test glob runtime-disable

check: defcompile test glob runtime-disable

defcompile:
	vim -N -u NONE -n -i NONE -es -S tests/defcompile.vim

test:
	vim -N -u NONE -n -i NONE -es -S tests/vim_smoke.vim

glob:
	vim -N -u NONE -n -i NONE -es -S tests/glob.vim

runtime-disable:
	vim -N -u NONE -n -i NONE -es -S tests/runtime_disable.vim
