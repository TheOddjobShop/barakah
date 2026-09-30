#!/bin/bash
# Barakah launcher, installed by `make` on Linux.
# The system Python is used on purpose: it is the one with PyGObject.
export PYTHONPATH="@APP_DIR@${PYTHONPATH:+:$PYTHONPATH}"
exec -a barakah @PYTHON@ -m barakah "$@"
