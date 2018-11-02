SHELL := /bin/bash

all:
	@./run.sh

%:
	@./run.sh $@

upgrade-%:
	@./run.sh $@
