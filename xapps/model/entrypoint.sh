#!/bin/sh
# This file is kept for reference only.
# Each xApp container (xapp-kpi, xapp-inference) ships its own entrypoint.sh
# that extracts the appropriate zip (client.zip or server.zip) from /model
# into /tmp/fhe_model/ at container startup.
#
# xapp-kpi/entrypoint.sh    – extracts client.zip
# xapp-inference/entrypoint.sh – extracts server.zip + client.zip
echo "This entrypoint is not used directly. See xapp-kpi/ and xapp-inference/ subdirs."
