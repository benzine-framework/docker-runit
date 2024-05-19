#!/bin/bash
set -e
# shellcheck disable=SC1091
source /installers/config
${APT_GET} \
	runit
