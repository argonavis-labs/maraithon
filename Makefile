.PHONY: setup generate build test verify verify-native verify-production-mobile deploy

setup:
	mix setup

generate:
	scripts/monorepo/generate

build:
	scripts/monorepo/build

test:
	scripts/monorepo/test

verify:
	scripts/monorepo/verify

verify-native:
	scripts/monorepo/verify native

verify-production-mobile:
	scripts/monorepo/mobile-production-verify

deploy:
	scripts/monorepo/deploy
