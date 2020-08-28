PG_MAJOR?=12
# All PG_VERSIONS binaries/libraries will be included in the Dockerfile
# specifying multiple versions will allow things like pg_upgrade etc to work.
PG_VERSIONS?=12 11
POSTGIS_VERSIONS?="2.5 3"

# CI/CD can benefit from specifying a specific apt packages mirror
DEBIAN_REPO_MIRROR?=""

# These variables have to do with this Docker repository
GIT_COMMIT=$(shell git describe --always --tag --long --abbrev=8)
GIT_BRANCH=$(shell git symbolic-ref --short HEAD)
GIT_REMOTE=$(shell git config --get remote.origin.url | sed 's/.*@//g')
GIT_STATUS=$(shell git status --porcelain | paste -sd "," -)
GIT_AUTHOR?=$(USER)
GIT_REV?=$(shell git rev-parse HEAD)

# These variables have to do with what software we pull in from github
GITHUB_USER?=""
GITHUB_TOKEN?=""
GITHUB_REPO?="timescale/timescaledb"
GITHUB_TAG?="master"

# This variable is set when running in gitlab CI/CD, and allows us to clone
# private repositories.
CI_JOB_TOKEN?=""

TAG?=$(subst /,_,$(GIT_BRANCH)-$(GIT_COMMIT))
REGISTRY?=localhost:5000
TIMESCALEDB_REPOSITORY?=timescale/timescaledb-docker-ha
TIMESCALEDB_IMAGE?=$(REGISTRY)/$(TIMESCALEDB_REPOSITORY)
TIMESCALEDB_BUILDER_URL?=$(TIMESCALEDB_IMAGE):builder
TIMESCALEDB_RELEASE_URL?=$(TIMESCALEDB_IMAGE):$(TAG)
TIMESCALEDB_LATEST_URL?=$(TIMESCALEDB_IMAGE):latest
PG_PROMETHEUS?=
TIMESCALE_PROMETHEUS?=0.1.0-beta.3
TIMESCALE_TSDB_ADMIN?=

CICDIMAGE=$(CICD_REPOSITORY):$(RELEASE_TAG)-pg$(PG_MAJOR)$(POSTFIX)
WIPTAG=$(TIMESCALEDB_RELEASE_URL)-pg$(PG_MAJOR)$(POSTFIX)-wip


CICD_REPOSITORY?=registry.gitlab.com/timescale/timescaledb-docker-ha
PUBLISH_REPOSITORY?=docker.io/timescaledev/timescaledb-ha

BUILDARGS=
POSTFIX=
INSTALL_METHOD?=docker-ha
DOCKER_IMAGE_CACHE?=$(TIMESCALEDB_BUILDER_URL)-pg$(PG_MAJOR)

builder-11:    PG_MAJOR  = 11
builder-12:    PG_MAJOR  = 12
build-all-11:  PG_MAJOR  = 11
build-all-12:  PG_MAJOR  = 12
build-oss:	   BUILDARGS = --build-arg OSS_ONLY=" -DAPACHE_ONLY=1"
build-tag: 	   BUILDARGS = --build-arg GITHUB_REPO=$(GITHUB_REPO) --build-arg GITHUB_USER=$(GITHUB_USER) --build-arg GITHUB_TOKEN=$(GITHUB_TOKEN) --build-arg GITHUB_TAG=$(GITHUB_TAG)

build-tag: 	   POSTFIX   = -$(GITHUB_TAG)
build-oss:     POSTFIX   = -oss
test-oss:      POSTFIX   = -oss
push-oss:      POSTFIX   = -oss
publish-oss:   POSTFIX   = -oss


# We label all the Docker Images with the versions of PostgreSQL, TimescaleDB and other extensions
# that are in versions.json.
# versions.json is generated by starting a builder container and querying the PostgreSQL catalogs
# for all the version information. In that way, we are sure we never tag the Docker images with the wrong
# versions.
# I'm using $$(jq) instead of $(shell), as we need to evaluate these variables for every new image build
DOCKER_BUILD_COMMAND=docker build  \
					 --build-arg PG_PROMETHEUS=$(PG_PROMETHEUS) \
					 --build-arg TIMESCALE_PROMETHEUS=$(TIMESCALE_PROMETHEUS) \
					 --build-arg POSTGIS_VERSIONS=$(POSTGIS_VERSIONS) \
					 --build-arg DEBIAN_REPO_MIRROR=$(DEBIAN_REPO_MIRROR) \
					 --build-arg PG_VERSIONS="$(PG_VERSIONS)" \
					 --build-arg TIMESCALE_TSDB_ADMIN="$(TIMESCALE_TSDB_ADMIN)" \
					 --build-arg CI_JOB_TOKEN="$(CI_JOB_TOKEN)" \
					 --cache-from $(DOCKER_IMAGE_CACHE) \
					 --label org.opencontainers.image.created="$$(date -Iseconds --utc)" \
					 --label org.opencontainers.image.revision="$(GIT_REV)" \
					 --label org.opencontainers.image.vendor=Timescale \
					 --label org.opencontainers.image.source="$(GIT_REMOTE)"

default: build

.PHONY: build build-oss build-tag
build build-oss build-tag: builder
	$(DOCKER_BUILD_COMMAND) --tag $(WIPTAG) --build-arg INSTALL_METHOD="$(INSTALL_METHOD)" --build-arg PG_MAJOR=$(PG_MAJOR) $(BUILDARGS) .
	# In these steps we do some introspection to find out some details of the versions
	# that are inside the Docker image. As we use the Debian packages, we do not know until
	# after we have built the image, what patch version of PostgreSQL, or PostGIS is installed.
	#
	# We will then attach this information as OCI labels to the final Docker image
	# https://github.com/opencontainers/image-spec/blob/master/annotations.md
	docker stop dummy$(PG_MAJOR)$(POSTFIX) || true
	docker run -d --rm --name dummy$(PG_MAJOR)$(POSTFIX) -e PGDATA=/tmp/pgdata --user=postgres $(WIPTAG) \
		sh -c 'initdb && timeout 30 postgres'
	docker exec -i dummy$(PG_MAJOR)$(POSTFIX) sh -c 'while ! pg_isready; do sleep 1; done'
	cat scripts/version_info.sql | docker exec -i dummy$(PG_MAJOR)$(POSTFIX) psql -AtXq | tee .$@
	docker stop dummy$(PG_MAJOR)$(POSTFIX)

	if [ ! -z "$(TIMESCALE_TSDB_ADMIN)" -a "$(POSTFIX)" != "-oss" ]; then echo "tsdb_admin=$(TIMESCALE_TSDB_ADMIN)" >> .$@; fi
	if [ ! -z "$(TIMESCALE_PROMETHEUS)" ]; then echo "timescale_prometheus=$(TIMESCALE_PROMETHEUS)" >> .$@; fi

	# This is where we build the final Docker Image, including all the version labels
	echo "FROM $(WIPTAG)" | docker build --tag $(TIMESCALEDB_RELEASE_URL)-pg$(PG_MAJOR)$(POSTFIX) - \
		$$(awk -F '=' '{printf "--label com.timescaledb.image."$$1".version="$$2" "}' .$@) --label com.timescaledb.image.install_method=$(INSTALL_METHOD)

	docker tag $(TIMESCALEDB_RELEASE_URL)-pg$(PG_MAJOR)$(POSTFIX) $(TIMESCALEDB_LATEST_URL)-pg$(PG_MAJOR)$(POSTFIX)

.PHONY: build-all
build-all:
	$(MAKE) build-all-$(PG_MAJOR)

.PHONY: build-all-11 build-all-12
build-all-11 build-all-12: build build-oss

.PHONY: builder builder-11 builder-12
builder-11 builder-12:
	$(DOCKER_BUILD_COMMAND) --target builder -t $(TIMESCALEDB_BUILDER_URL)-pg$(PG_MAJOR) --build-arg PG_MAJOR=$(PG_MAJOR) $(BUILDARGS) .

builder:
	$(MAKE) builder-$(PG_MAJOR)

.PHONY: push-builder
push-builder: builder
	docker push $(TIMESCALEDB_BUILDER_URL)-pg$(PG_MAJOR)

.PHONY: push push-oss
push push-oss: push% : build%
	docker push $(TIMESCALEDB_RELEASE_URL)-pg$(PG_MAJOR)$(POSTFIX) \
	&& docker push $(TIMESCALEDB_LATEST_URL)-pg$(PG_MAJOR)$(POSTFIX)

.PHONY: push-all
push-all: push push-oss

# The purpose of publishing the images under many tags, is to provide
# some choice to the user as to their appetite for volatility.
#
#  1. timescaledev/timescaledb-ha:pg12-latest
#  2. timescaledev/timescaledb-ha:pg12-ts1.7-latest
#  3. timescaledev/timescaledb-ha:pg12.3-ts1.7-latest
#  4. timescaledev/timescaledb-ha:pg12.3-ts1.7.1-latest
#  5. timescaledev/timescaledb-ha:pg12.3-ts1.7.1-pN
#
# Tag 5 is immutable, and for every time we publish that image, we increase N by 1,
# we start with N=0
#
# Our method of finding a patch version is quite brute force (`docker pull image`), 
# however, this should not happen that often.
.PHONY: publish publish-oss
publish publish-oss:
	export PGVERSION=$$(docker inspect $(CICDIMAGE) | jq '.[0]."ContainerConfig"."Labels"."com.timescaledb.image.postgresql.version"' -r) \
	&& export TSPATCH=$$(docker inspect $(CICDIMAGE) | jq '.[0]."ContainerConfig"."Labels"."com.timescaledb.image.timescaledb.version"' -r) \
	&& export TSMINOR=$${TSPATCH%.*} \
	&& for variant in pg$(PG_MAJOR)$(POSTFIX)-latest pg$(PG_MAJOR)-ts$${TSMINOR}$(POSTFIX)-latest pg$${PGVERSION}-ts$${TSMINOR}$(POSTFIX)-latest pg$${PGVERSION}-ts$${TSPATCH}$(POSTFIX)-latest; \
		do \
			docker tag $(CICDIMAGE) $(PUBLISH_REPOSITORY):$${variant} \
			&& docker push $(PUBLISH_REPOSITORY):$${variant} || exit 1; \
		done \
	&& for i in $$(seq 0 100); do \
		export IMMUTABLE_TAG=$(PUBLISH_REPOSITORY):pg$${PGVERSION}-ts$${TSPATCH}$(POSTFIX)-p$${i} \
		&& if docker pull $${IMMUTABLE_TAG}; \
			then \
				echo "$${IMMUTABLE_TAG} already exists"; \
			else \
				docker tag $(CICDIMAGE) $${IMMUTABLE_TAG}; \
				docker push $${IMMUTABLE_TAG} && exit 0 || exit 1; \
			fi; \
	   done

.PHONY: publish
publish-all:
ifndef RELEASE_TAG
	$(error RELEASE_TAG is undefined, please set it to a tag that was succesfully built)
endif
	@echo "This operation will push new Docker images to the timescaledev public Docker hub"
	@echo "including an immutable one for production environments."
	@echo "This will publish images for the tag $${RELEASE_TAG}"
	@echo ""
	@echo -n "Are you sure? [y/N] " && read ans && [ $${ans:-N} = y ]
	$(MAKE) publish publish-oss

.PHONY: test
test test-oss: test%: build%
	# Very simple test that verifies the following things:
	# - PATH has the correct setting
	# - initdb succeeds
	# - timescaledb is correctly injected into the default configuration
	#
	# TODO: Create a good test-suite. For now, it's nice to have this target in CI/CD,
	# and have it do something worthwhile
	docker run --rm --tty $(TIMESCALEDB_RELEASE_URL)-pg$(PG_MAJOR)$(POSTFIX) /bin/bash -c "initdb -D test && grep timescaledb test/postgresql.conf"

clean:
	rm -f .builder
