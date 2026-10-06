#!/bin/sh

set -eu

. /usr/share/vohive/task_lib.sh

task_run_sync rollback_core
