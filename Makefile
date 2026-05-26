.PHONY: setup \
	generate generate-native generate-companion generate-mobile \
	build build-web build-api build-static build-assets build-native build-companion build-mobile \
	test test-web test-api test-native test-companion test-mobile \
	verify verify-web verify-api verify-static verify-assets verify-native verify-companion verify-mobile verify-production-mobile \
	deploy deploy-web

setup:
	mix setup

generate:
	scripts/monorepo/generate

generate-native:
	scripts/monorepo/generate native

generate-companion:
	scripts/monorepo/generate companion

generate-mobile:
	scripts/monorepo/generate mobile

build:
	scripts/monorepo/build

build-web:
	scripts/monorepo/build web

build-api: build-web

build-static:
	scripts/monorepo/assets web

build-assets:
	scripts/monorepo/assets all

build-native:
	scripts/monorepo/build native

build-companion:
	scripts/monorepo/build companion

build-mobile:
	scripts/monorepo/build mobile

test:
	scripts/monorepo/test

test-web:
	scripts/monorepo/test web

test-api: test-web

test-native:
	scripts/monorepo/test native

test-companion:
	scripts/monorepo/test companion

test-mobile:
	scripts/monorepo/test mobile

verify:
	scripts/monorepo/verify

verify-web:
	scripts/monorepo/verify web

verify-api: verify-web

verify-static:
	scripts/monorepo/verify static

verify-assets:
	scripts/monorepo/verify assets

verify-native:
	scripts/monorepo/verify native

verify-companion:
	scripts/monorepo/verify companion

verify-mobile:
	scripts/monorepo/verify mobile

verify-production-mobile:
	scripts/monorepo/mobile-production-verify

deploy:
	scripts/monorepo/deploy

deploy-web: deploy
