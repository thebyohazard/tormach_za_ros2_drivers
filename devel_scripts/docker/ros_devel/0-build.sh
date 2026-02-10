#!/bin/bash -e
WANT_ENV="docker-build docker-run"
. $(dirname $0)/../env.sh
set -x

# Ensure apt cache is up to date
apt-get update

# Clean everything out of /usr/local for easy, clean copying into
# mainline build stage.  This might be easier than installing to some
# DESTDIR, but might be prone to failures.
rm -rf /usr/local/*
mkdir -p /usr/local/{etc,sbin,share,share/man,bin,include}

###########################
# Tools
###########################

# Put stuff in /usr/local; binaries will be in /usr/local/go/bin
export GOPATH=/usr/local/go

# shfmt
apt-get install -y \
    golang
GO111MODULE=on go install mvdan.cc/sh/v3/cmd/shfmt@v3.3.1
# - Put executable in $PATH
ln -s ../go/bin/shfmt /usr/local/bin/shfmt

# Install dev tools via apt (avoids PEP 668 pip restrictions on Python 3.12+)
apt-get install -y \
    cmake-format \
    python3-kitchen \
    python3-sphinx \
    python3-rosdoc2 \
    black \
    pre-commit \
    python3-flake8 \
    python3-pep8-naming

# - Monkey-patch identify module to recognize .launch files
sed -i -e "/'kt'/ a \    \'launch\': {\'text\', \'xml\'}," \
    /usr/lib/python3/dist-packages/identify/extensions.py

# Installing from source for now. This was where the humble image installed the file.
# apt-get install -y \
#     machinekit-hal-dev
