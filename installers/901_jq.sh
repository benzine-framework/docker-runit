#!/bin/bash
set -e
# shellcheck disable=SC1091
source /usr/local/lib/marshall_installer
add_ppa ppa:rmescandon/yq
install yq jq
