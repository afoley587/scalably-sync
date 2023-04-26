#!/bin/bash

export VARS_FILE="compliance.yml"

poetry run ansible-playbook main.yml