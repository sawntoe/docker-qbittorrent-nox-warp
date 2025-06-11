#!/bin/bash

set -e

sudo -u qbtUser /warp-entrypoint.sh
/qbt-entrypoint.sh
