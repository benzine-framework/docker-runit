#!/bin/bash
# shellcheck disable=SC1091
source /usr/local/lib/marshall_installer
title "Utils"
install \
	inetutils-ping \
	nano \
	curl \
	wget \
	unzip
