include $(TOPDIR)/rules.mk

PKG_NAME:=nexawrt-repository
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKGARCH:=all
PKG_LICENSE:=MIT
PKG_MAINTAINER:=NexaWrt Maintainers

include $(INCLUDE_DIR)/package.mk

define Package/nexawrt-repository
  SECTION:=net
  CATEGORY:=NexaWrt
  TITLE:=NexaWrt signed APK repository support
  DEPENDS:=+apk
endef

define Package/nexawrt-repository/description
 Installs NexaWrt repository metadata and a small repository status helper.
 The repository URL and signing key are already embedded in NexaWrt images.
endef

define Build/Compile
endef

define Package/nexawrt-repository/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/nexawrt-repo-status $(1)/usr/sbin/nexawrt-repo-status
	$(INSTALL_DIR) $(1)/usr/share/nexawrt
	$(INSTALL_DATA) ./files/repository.conf $(1)/usr/share/nexawrt/repository.conf
endef

$(eval $(call BuildPackage,nexawrt-repository))
