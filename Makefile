SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

ifneq (,$(wildcard .env))
include .env
export
endif

ROOT_DIR := $(abspath .)
TF_DIR := $(ROOT_DIR)/infra/terraform
ANSIBLE_DIR := $(ROOT_DIR)/infra/ansible
INVENTORY := $(ANSIBLE_DIR)/generated/inventory.ini

.PHONY: deps deps-check connect-client-help ssh-check infra config deploy test clean tf-init tf-validate ansible-lint

deps:
	$(ROOT_DIR)/install.sh

deps-check:
	$(ROOT_DIR)/install.sh --check

connect-client-help:
	$(ROOT_DIR)/infra/scripts/connect-client.sh --help

ssh-check:
	$(ROOT_DIR)/infra/scripts/preflight-ssh.sh $(INVENTORY) wireguard_server

infra: tf-init
	cd $(TF_DIR) && terraform apply -auto-approve

config:
	$(ROOT_DIR)/infra/scripts/setup-wireguard.sh $(INVENTORY)
	$(ROOT_DIR)/infra/scripts/setup-coredns.sh $(INVENTORY)

deploy:
	$(ROOT_DIR)/infra/scripts/run-container.sh $(INVENTORY)

test:
	$(ROOT_DIR)/infra/scripts/validate-connectivity.sh $(INVENTORY)

clean:
	cd $(TF_DIR) && terraform destroy -auto-approve || true
	rm -rf $(ANSIBLE_DIR)/generated

tf-init:
	cd $(TF_DIR) && terraform init

tf-validate: tf-init
	cd $(TF_DIR) && terraform fmt -check -recursive && terraform validate

ansible-lint:
	ansible-playbook -i $(ANSIBLE_DIR)/inventory.example.ini $(ANSIBLE_DIR)/wireguard.yml --syntax-check
	ansible-playbook -i $(ANSIBLE_DIR)/inventory.example.ini $(ANSIBLE_DIR)/coredns.yml --syntax-check
	ansible-playbook -i $(ANSIBLE_DIR)/inventory.example.ini $(ANSIBLE_DIR)/docker.yml --syntax-check
