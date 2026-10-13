WIN32_DIR = $(PLATFORM_DIR)/win32
WIN32_PACKAGE_NAME = koreader-win32-$(WIN32_ARCH)$(KODEDUG_SUFFIX)-$(VERSION)
WIN32_PORTABLE_PACKAGE = $(WIN32_PACKAGE_NAME).zip
WIN32_INSTALLER = $(WIN32_PACKAGE_NAME)-setup.exe
WIN32_STAGING_DIR = $(INSTALL_DIR)/win32
WIN32_RELEASE_DIR = $(WIN32_STAGING_DIR)/KOReader

define UPDATE_PATH_EXCLUDES +=
plugins/SSH.koplugin
plugins/autofrontlight.koplugin
plugins/externalkeyboard.koplugin
plugins/hello.koplugin
plugins/terminal.koplugin
plugins/timesync.koplugin
tools
endef

# Launcher. {{{

WIN32_LAUNCHER = $(INSTALL_DIR)/koreader/koreader.exe
WIN32_LAUNCHER_RES = $(WIN32_STAGING_DIR)/launcher.res.o
WIN32_VERSION_STAMP = $(WIN32_STAGING_DIR)/version.stamp

# Numeric version for the resources, e.g. `v2026.07.2-241-g…` → `2026,7,2,241`.
WIN32_VERSION_NUM := $(shell printf '%s' '$(VERSION)' \
	| sed -nE 's/^v([0-9]+)\.([0-9]+)(\.([0-9]+))?(-([0-9]+))?.*$$/\1,\2,\4,\6/p' \
	| awk -F, '{ printf "%d,%d,%d,%d", $$1, $$2, $$3, $$4 }')

all: $(WIN32_LAUNCHER)

# Only rebuild the resources when the version changes.
$(WIN32_VERSION_STAMP): FORCE
	mkdir -p $(dir $@)
	printf '%s\n' '$(VERSION)' | cmp -s - $@ || printf '%s\n' '$(VERSION)' >$@

$(WIN32_LAUNCHER_RES): $(WIN32_DIR)/launcher.rc $(WIN32_DIR)/koreader.ico $(WIN32_VERSION_STAMP)
	$(RC) -O coff -I $(WIN32_DIR) \
		-DKO_VERSION_NUM='$(or $(WIN32_VERSION_NUM),0,0,0,0)' \
		-DKO_VERSION_STR='\"$(VERSION)\"' \
		-i $< -o $@

$(WIN32_LAUNCHER): $(WIN32_DIR)/launcher.c $(WIN32_LAUNCHER_RES) $(WIN32_MANIFEST_OBJ)
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -municode -mwindows -I$(STAGING_DIR)/include/luajit-2.1 \
		-o $@ $< $(WIN32_LAUNCHER_RES) $(WIN32_MANIFEST_OBJ) \
		$(LDFLAGS) -L$(STAGING_DIR)/lib -lluajit -lole32 -lshell32 -luuid
	$(STRIP) --strip-unneeded $@

PHONY += FORCE
FORCE:

# }}}

# Release. {{{

update-prepare: all
	# Ensure that the binaries were built for Windows.
	file --dereference $(INSTALL_DIR)/koreader/koreader.exe | grep -q 'PE32+\? executable'
	rm -rf $(WIN32_RELEASE_DIR)
	cd $(INSTALL_DIR)/koreader && '$(abspath tools/mkrelease.sh)' $(abspath $(WIN32_RELEASE_DIR))/ . $(release_excludes)

# Portable archive: settings & data are stored alongside the program.
update-zip: update-prepare
	cp $(WIN32_DIR)/portable.txt $(WIN32_RELEASE_DIR)/
	rm -f $(WIN32_PORTABLE_PACKAGE)
	cd $(WIN32_STAGING_DIR) && '$(abspath tools/mkrelease.sh)' --epoch=$(RELEASE_EPOCH) $(if $(PARALLEL_JOBS),--jobs $(PARALLEL_JOBS)) $(abspath $(WIN32_PORTABLE_PACKAGE)) KOReader
	rm -f $(WIN32_RELEASE_DIR)/portable.txt

# Installer: settings & data are stored in the user profile.
update-installer: update-prepare
	$(WIN32_DIR)/gen_files_list.sh $(WIN32_RELEASE_DIR) >$(WIN32_STAGING_DIR)/files_list.nsh
	makensis -V3 -INPUTCHARSET UTF8 \
		-DVERSION='$(VERSION)' \
		-DVERSION_NUM='$(subst $(comma),.,$(or $(WIN32_VERSION_NUM),0,0,0,0))' \
		-DARCH='$(WIN32_ARCH)' \
		-DSRC_DIR='$(abspath $(WIN32_RELEASE_DIR))' \
		-DFILES_LIST='$(abspath $(WIN32_STAGING_DIR)/files_list.nsh)' \
		-DOUT_FILE='$(abspath $(WIN32_INSTALLER))' \
		-DICON='$(abspath $(WIN32_DIR)/koreader.ico)' \
		-DLICENSE='$(abspath COPYING)' \
		$(WIN32_DIR)/installer.nsi

update: update-zip update-installer

PHONY += update-prepare update-zip update-installer

# }}}

# vim: foldmethod=marker foldlevel=0
