#!/usr/bin/env bash
# Create a temporary git repo with a known set of commits for testing.
# Prints the repo path on stdout.

set -euo pipefail

repo=$(mktemp -d -t code-review-test.XXXXXX)
cd "$repo"

git init -q -b main
git config user.email "test@example.com"
git config user.name "Test"
git config commit.gpgsign false

cat > greeting.txt <<EOF
Hello, world.
This is the original file.
Line three.
EOF
git add greeting.txt
git commit -q -m "Initial commit"

cat > greeting.txt <<EOF
Hello, world.
This is the modified file.
Line three.
Line four added.
EOF
git add greeting.txt
git commit -q -m "Modify greeting"

# Working tree change (uncommitted)
cat > greeting.txt <<EOF
Hello, world.
This is the working tree version.
Line three.
Line four added.
Line five uncommitted.
EOF

echo "$repo"
