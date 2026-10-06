ROUTER ?= 192.168.6.1
SSH ?= ssh
SCP ?= scp
REMOTE ?= root@$(ROUTER)
IPK_DIR ?= bin/packages
CORE_ARCH ?= amd64
PACKAGE_EXT ?= ipk
INSTALL_CMD ?= opkg install

.PHONY: deploy deploy-core

deploy:
	$(SCP) $$(find $(IPK_DIR) -name 'luci-app-vohive*.$(PACKAGE_EXT)' | head -n 1) $(REMOTE):/tmp/
	$(SSH) $(REMOTE) '$(INSTALL_CMD) /tmp/luci-app-vohive*.$(PACKAGE_EXT)'

deploy-core:
	$(SCP) $$(find $(IPK_DIR) -name 'vohive-core-$(CORE_ARCH)*.$(PACKAGE_EXT)' | head -n 1) $(REMOTE):/tmp/
	$(SSH) $(REMOTE) '$(INSTALL_CMD) /tmp/vohive-core-$(CORE_ARCH)*.$(PACKAGE_EXT)'
