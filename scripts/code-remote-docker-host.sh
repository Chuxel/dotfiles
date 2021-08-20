#!/usr/bin/env bash
export DOCKER_HOST=ssh://$1
code ${2:-"."}
