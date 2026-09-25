# A Makefile is a list of named shortcuts ("targets"). Run one with `make <name>`.
# Each target has the form:
#
#   name:  ## description
#   <TAB>command to run
#
# The command lines MUST start with a real tab character, not spaces.

# Targets that are commands, not files. Without this, `make` would look for a
# file called "build" and skip the command if one existed.
.PHONY: help build run stop restart test clean app

# The default target: what runs when you type just `make`.
help:  ## Show this list of commands
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-8s %s\n", $$1, $$2}'

build:  ## Compile the app (debug build, output goes in .build/)
	swift build

run: stop  ## Build and launch the app (Ctrl-C to quit). Press Cmd+Space to use it
	scripts/dev-app.sh
	.build/Spotlight.app/Contents/MacOS/Spotlight

# Match our copies by path, not just by name: Apple's own Spotlight is also a
# process called "Spotlight" (in /System/Library/CoreServices), and
# `pkill -x Spotlight` would kill it too.
stop:  ## Quit any running copy of the app
	-@pkill -f '(\.build/.*|dist/Spotlight\.app/Contents/MacOS|^/Applications/Spotlight\.app/Contents/MacOS)/Spotlight$$'

restart: stop  ## Rebuild, then launch in the background
	scripts/dev-app.sh
	.build/Spotlight.app/Contents/MacOS/Spotlight &

test:  ## Run the unit tests in Tests/
	swift test

app:  ## Build a signed Spotlight.app + zip in dist/ (make app VERSION=0.1.0)
	scripts/package.sh $(or $(VERSION),dev)

clean:  ## Delete build output (.build/); the next build starts fresh
	swift package clean
	rm -rf .build
