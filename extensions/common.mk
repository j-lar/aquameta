EXTENSION = $(MODULE)
EXTVERSION = 0.5.0
DATA = $(MODULE)--$(EXTVERSION).sql

$(MODULE)--$(EXTVERSION).sql: $(SQL_FILES) extension.sql
	grep -hv '^\s*begin;\s*$$\|^\s*commit;\s*$$\|^\s*create schema bundle;\s*$$\|^\s*set search_path=bundle;\s*$$' $(SQL_FILES) > $@
	cat extension.sql >> $@

PGXS := $(shell pg_config --pgxs)
include $(PGXS)
