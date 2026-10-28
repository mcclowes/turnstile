#!/bin/bash
# Prints turnstile's version, as set in Turnstile.version.
set -euo pipefail
cd "$(dirname "$0")/.."
sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/TurnstileCore/Paths.swift
