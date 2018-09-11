SHELL=/bin/bash -o pipefail

DOCKER_SERVER?=registry.cn-shanghai.aliyuncs.com
K8S_PROJECT?=ccs-dev
REPO?=$(DOCKER_SERVER)/$(K8S_PROJECT)/prometheus-operator
REPO_PROMETHEUS_CONFIG_RELOADER?=$(DOCKER_SERVER)/$(K8S_PROJECT)/prometheus-config-reloader
TAG?=$(shell git tag | sort -V | tail -1)

PO_CRDGEN_BINARY:=$(GOPATH)/bin/po-crdgen
OPENAPI_GEN_BINARY:=$(GOPATH)/bin/openapi-gen
DEEPCOPY_GEN_BINARY:=$(GOPATH)/bin/deepcopy-gen
GOJSONTOYAML_BINARY:=$(GOPATH)/bin/gojsontoyaml
JB_BINARY:=$(GOPATH)/bin/jb
PO_DOCGEN_BINARY:=$(GOPATH)/bin/po-docgen
EMBEDMD_BINARY:=$(GOPATH)/bin/embedmd

GOLANG_FILES:=$(shell find . -name \*.go -print)
pkgs = $(shell go list ./... | grep -v /vendor/ | grep -v /test/)


.PHONY: all
all: format generate build test image
	@echo
	@echo "$${BOLD}# now we're ready for: $${GREEN}make install$${RESET}"
	@echo

.PHONY: clean
clean:
	rm -f operator prometheus-config-reloader
	rm -f hack/operator-image hack/prometheus-config-reloader-image
	rm -fr ./hack/generate/vendor/.tmp
	@echo
	docker rmi $(REPO):$(TAG) 2>/dev/null || true
	@echo
	docker rmi $(REPO_PROMETHEUS_CONFIG_RELOADER):$(TAG) 2>/dev/null || true
	@echo
	@echo "$${BOLD}# now we're ready for: $${GREEN}make$${RESET}"
	@echo

.PHONY: prep-gke-no-collectd
prep-gke-no-collectd:
	perl -pi -e 's,UPDATE-ME,    cloud.google.com/load-balancer-type: Internal,' contrib/kube-prometheus/manifests/grafana-service.yaml
	perl -pi -e 's,UPDATE-ME,    cloud.google.com/load-balancer-type: Internal,' contrib/kube-prometheus/manifests/prometheus-service.yaml
	perl -pi -e 's,UPDATE-ME,  type: pd-ssd\nprovisioner: kubernetes.io/gce-pd,' contrib/kube-prometheus/manifests/prometheus-storageclass.yaml

.PHONY: prep-acs-no-collectd
prep-acs-no-collectd:
	perl -pi -e 's,UPDATE-ME,    service.beta.kubernetes.io/alicloud-loadbalancer-address-type: intranet,' contrib/kube-prometheus/manifests/grafana-service.yaml
	perl -pi -e 's,UPDATE-ME,    service.beta.kubernetes.io/alicloud-loadbalancer-address-type: intranet,' contrib/kube-prometheus/manifests/prometheus-service.yaml
	perl -pi -e 's,UPDATE-ME,  type: cloud_ssd\nprovisioner: alicloud/disk,' contrib/kube-prometheus/manifests/prometheus-storageclass.yaml

.PHONY: install-0
install-0:
	KUBECONFIG=$(KUBECONFIG) kubectl apply -f contrib/kube-prometheus/manifests/00namespace-namespace.yaml
	@echo
	KUBECONFIG=$(KUBECONFIG) kubectl apply -f bundle.yaml
	KUBECONFIG=$(KUBECONFIG) kubectl --namespace=default delete deployment prometheus-operator

.PHONY: install-no-grafana
install-no-grafana:
	rm -f contrib/kube-prometheus/manifests/grafana-*
	KUBECONFIG=$(KUBECONFIG) kubectl apply -f contrib/kube-prometheus/manifests
	git checkout contrib/kube-prometheus/manifests/grafana-*

.PHONY: install
install:
	KUBECONFIG=$(KUBECONFIG) kubectl apply -f contrib/kube-prometheus/manifests

.PHONY: uninstall
uninstall:
	KUBECONFIG=$(KUBECONFIG) kubectl delete -f contrib/kube-prometheus/manifests/00namespace-namespace.yaml || true
	@echo
	KUBECONFIG=$(KUBECONFIG) kubectl delete -f bundle.yaml || true


############
# Building #
############

.PHONY: build
build: operator prometheus-config-reloader

operator: $(GOLANG_FILES)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build \
	-ldflags "-X github.com/coreos/prometheus-operator/pkg/version.Version=$(shell cat VERSION)" \
	-o $@ cmd/operator/main.go

prometheus-config-reloader:
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build \
	-ldflags "-X github.com/coreos/prometheus-operator/pkg/version.Version=$(shell cat VERSION)" \
	-o $@ cmd/$@/main.go

pkg/client/monitoring/v1/zz_generated.deepcopy.go: .header pkg/client/monitoring/v1/types.go $(DEEPCOPY_GEN_BINARY)
	$(DEEPCOPY_GEN_BINARY) \
	-i github.com/coreos/prometheus-operator/pkg/client/monitoring/v1 \
	--go-header-file="$(GOPATH)/src/github.com/coreos/prometheus-operator/.header" \
	-v=4 \
	--logtostderr \
	--bounding-dirs "github.com/coreos/prometheus-operator/pkg/client" \
	--output-file-base zz_generated.deepcopy

pkg/client/monitoring/v1alpha1/zz_generated.deepcopy.go: $(DEEPCOPY_GEN_BINARY)
	$(DEEPCOPY_GEN_BINARY) \
	-i github.com/coreos/prometheus-operator/pkg/client/monitoring/v1alpha1 \
	--go-header-file="$(GOPATH)/src/github.com/coreos/prometheus-operator/.header" \
	-v=4 \
	--logtostderr \
	--bounding-dirs "github.com/coreos/prometheus-operator/pkg/client" \
	--output-file-base zz_generated.deepcopy

.PHONY: image
image: hack/operator-image hack/prometheus-config-reloader-image

hack/operator-image: Dockerfile operator
# Create empty target file, for the sole purpose of recording when this target
# was last executed via the last-modification timestamp on the file. See
# https://www.gnu.org/software/make/manual/make.html#Empty-Targets
	docker build -t $(REPO):$(TAG) .
	docker push $(REPO):$(TAG)
	touch $@

hack/prometheus-config-reloader-image: cmd/prometheus-config-reloader/Dockerfile prometheus-config-reloader
# Create empty target file, for the sole purpose of recording when this target
# was last executed via the last-modification timestamp on the file. See
# https://www.gnu.org/software/make/manual/make.html#Empty-Targets
	docker build -t $(REPO_PROMETHEUS_CONFIG_RELOADER):$(TAG) -f cmd/prometheus-config-reloader/Dockerfile .
	docker push $(REPO_PROMETHEUS_CONFIG_RELOADER):$(TAG)
	touch $@


##############
# Generating #
##############

.PHONY: generate
generate: pkg/client/monitoring/v1/zz_generated.deepcopy.go pkg/client/monitoring/v1/openapi_generated.go $(shell find jsonnet/prometheus-operator/*-crd.libsonnet -type f) bundle.yaml kube-prometheus $(shell find Documentation -type f)

.PHONY: generate-in-docker
generate-in-docker: hack/jsonnet-docker-image
	docker run \
	--rm \
	-u=$(shell id -u $(USER)):$(shell id -g $(USER)) \
	-v `pwd`:/go/src/github.com/coreos/prometheus-operator \
	po-jsonnet make generate

.PHONY: kube-prometheus
kube-prometheus:
	cd contrib/kube-prometheus && $(MAKE) generate

example/prometheus-operator-crd/**.crd.yaml: pkg/client/monitoring/v1/openapi_generated.go $(PO_CRDGEN_BINARY)
	po-crdgen prometheus > example/prometheus-operator-crd/prometheus.crd.yaml
	po-crdgen alertmanager > example/prometheus-operator-crd/alertmanager.crd.yaml
	po-crdgen servicemonitor > example/prometheus-operator-crd/servicemonitor.crd.yaml
	po-crdgen prometheusrule > example/prometheus-operator-crd/prometheusrule.crd.yaml

jsonnet/prometheus-operator/**-crd.libsonnet: $(shell find example/prometheus-operator-crd/*.crd.yaml -type f) $(GOJSONTOYAML_BINARY)
	cat example/prometheus-operator-crd/alertmanager.crd.yaml   | gojsontoyaml -yamltojson > jsonnet/prometheus-operator/alertmanager-crd.libsonnet
	cat example/prometheus-operator-crd/prometheus.crd.yaml     | gojsontoyaml -yamltojson > jsonnet/prometheus-operator/prometheus-crd.libsonnet
	cat example/prometheus-operator-crd/servicemonitor.crd.yaml | gojsontoyaml -yamltojson > jsonnet/prometheus-operator/servicemonitor-crd.libsonnet
	cat example/prometheus-operator-crd/prometheusrule.crd.yaml | gojsontoyaml -yamltojson > jsonnet/prometheus-operator/prometheusrule-crd.libsonnet

pkg/client/monitoring/v1/openapi_generated.go: pkg/client/monitoring/v1/types.go $(OPENAPI_GEN_BINARY)
	$(OPENAPI_GEN_BINARY) \
	-i github.com/coreos/prometheus-operator/pkg/client/monitoring/v1,k8s.io/apimachinery/pkg/apis/meta/v1,k8s.io/api/core/v1 \
	-p github.com/coreos/prometheus-operator/pkg/client/monitoring/v1 \
	--go-header-file="$(GOPATH)/src/github.com/coreos/prometheus-operator/.header"

bundle.yaml: $(shell find example/rbac/prometheus-operator/*.yaml -type f)
	hack/generate-bundle.sh

hack/generate/vendor: $(JB_BINARY) $(shell find jsonnet/prometheus-operator -type f)
	cd hack/generate; $(JB_BINARY) install;

example/non-rbac/prometheus-operator.yaml: hack/generate/vendor hack/generate/prometheus-operator-non-rbac.jsonnet $(shell find jsonnet -type f)
	hack/generate/build-non-rbac-prometheus-operator.sh

RBAC_MANIFESTS = example/rbac/prometheus-operator/prometheus-operator-cluster-role.yaml example/rbac/prometheus-operator/prometheus-operator-cluster-role-binding.yaml example/rbac/prometheus-operator/prometheus-operator-service-account.yaml example/rbac/prometheus-operator/prometheus-operator-deployment.yaml
$(RBAC_MANIFESTS): hack/generate/vendor hack/generate/prometheus-operator-rbac.jsonnet $(shell find jsonnet -type f)
	hack/generate/build-rbac-prometheus-operator.sh

jsonnet/prometheus-operator/prometheus-operator.libsonnet: VERSION
	sed -i \
		"s/prometheusOperator: 'v.*',/prometheusOperator: 'v$(shell cat VERSION)',/" \
		jsonnet/prometheus-operator/prometheus-operator.libsonnet;

FULLY_GENERATED_DOCS = Documentation/api.md Documentation/compatibility.md
TO_BE_EXTENDED_DOCS = $(filter-out $(FULLY_GENERATED_DOCS), $(wildcard Documentation/*.md))

Documentation/api.md: $(PO_DOCGEN_BINARY) pkg/client/monitoring/v1/types.go
	$(PO_DOCGEN_BINARY) api pkg/client/monitoring/v1/types.go > $@

Documentation/compatibility.md: $(PO_DOCGEN_BINARY) pkg/prometheus/statefulset.go
	$(PO_DOCGEN_BINARY) compatibility > $@

$(TO_BE_EXTENDED_DOCS): $(EMBEDMD_BINARY) $(shell find example) kube-prometheus
	$(EMBEDMD_BINARY) -w `find Documentation -name "*.md" | grep -v vendor`


##############
# Formatting #
##############

.PHONY: format
format: go-fmt check-license shellcheck

.PHONY: go-fmt
go-fmt:
	go fmt $(pkgs)

.PHONY: check-license
check-license:
	./scripts/check_license.sh

.PHONY: shellcheck
shellcheck:
	docker run -v "${PWD}:/mnt" koalaman/shellcheck:stable $(shell find . -type f -name "*.sh" -not -path "*vendor*")


###########
# Testing #
###########

.PHONY: test
test: # test-unit test-e2e

.PHONY: test-unit
test-unit:
	@go test $(TEST_RUN_ARGS) -short $(pkgs)

.PHONY: test-e2e
test-e2e: NAMESPACE?=po-e2e-$(shell LC_ALL=C tr -dc a-z0-9 < /dev/urandom | head -c 13 ; echo '')
test-e2e: KUBECONFIG=$(KUBECONFIG)
test-e2e:
	go test -timeout 55m -v ./test/e2e/ $(TEST_RUN_ARGS) --kubeconfig=$(KUBECONFIG) --operator-image=$(REPO):$(TAG) --namespace=$(NAMESPACE)

.PHONY: test-e2e-helm
test-e2e-helm:
	./helm/hack/e2e-test.sh
	# package the chart and verify if they have the version bumped
	helm/hack/helm-package.sh "alertmanager grafana prometheus prometheus-operator exporter-kube-dns exporter-kube-scheduler exporter-kubelets exporter-node exporter-kube-controller-manager exporter-kube-etcd exporter-kube-state exporter-kubernetes exporter-coredns"
	helm/hack/sync-repo.sh false


########
# Misc #
########

hack/jsonnet-docker-image: scripts/jsonnet/Dockerfile
	docker build -f scripts/jsonnet/Dockerfile -t po-jsonnet .
	touch $@

.PHONY: helm-sync-s3
helm-sync-s3:
	helm/hack/helm-package.sh "alertmanager grafana prometheus prometheus-operator exporter-kube-dns exporter-kube-scheduler exporter-kubelets exporter-node exporter-kube-controller-manager exporter-kube-etcd exporter-kube-state exporter-kubernetes exporter-coredns"
	helm/hack/sync-repo.sh true
	helm/hack/helm-package.sh kube-prometheus
	helm/hack/sync-repo.sh true


############
# Binaries #
############

$(EMBEDMD_BINARY):
	@go get github.com/campoy/embedmd

$(JB_BINARY):
	go get -u github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb

$(PO_CRDGEN_BINARY): cmd/po-crdgen/main.go pkg/client/monitoring/v1/openapi_generated.go
	go install github.com/coreos/prometheus-operator/cmd/po-crdgen

$(PO_DOCGEN_BINARY): $(shell find cmd/po-docgen -type f) pkg/client/monitoring/v1/types.go
	go install github.com/coreos/prometheus-operator/cmd/po-docgen

$(OPENAPI_GEN_BINARY):
	go get -u -v -d k8s.io/code-generator/cmd/openapi-gen
	cd $(GOPATH)/src/k8s.io/code-generator; git checkout release-1.11
	go install k8s.io/code-generator/cmd/openapi-gen

$(DEEPCOPY_GEN_BINARY):
	go get -u -v -d k8s.io/code-generator/cmd/deepcopy-gen
	cd $(GOPATH)/src/k8s.io/code-generator; git checkout release-1.11
	go install k8s.io/code-generator/cmd/deepcopy-gen

$(GOJSONTOYAML_BINARY):
	go get -u github.com/brancz/gojsontoyaml
