#!/bin/sh
set -e

# This file is a small source part for the demo installer.
# It is intentionally simple and safe to edit.

APP_NAME="Modular build demo"
say_hello() {
    echo "$APP_NAME"
    echo "This output was assembled from small source files."
}

show_proxy0_example() {
    echo "Proxy0 configuration would live in a separate small file."
}
say_hello
show_proxy0_example

echo "Done."
