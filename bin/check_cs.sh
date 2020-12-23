#!/bin/bash
set -e

./vendor/bin/php-cs-fixer fix -v --dry-run --show-progress=estimating
