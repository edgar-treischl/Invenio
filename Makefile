.PHONY: help test-services test-app test-dataset test-record test-all \
        deploy logs restart stop

SUPERVISOR_CONF ?= $(HOME)/invenio-supervisor.conf
VENV            ?= $(HOME)/invenio-venv
INSTANCE        ?= $(HOME)/invenio-instance

help:
	@echo ""
	@echo "InvenioRDM PoC — available targets"
	@echo ""
	@echo "  make deploy           Full deployment on Ubuntu 22.04 VM (run once)"
	@echo ""
	@echo "  make test-services    Check all infrastructure services are up"
	@echo "  make test-app         Smoke-test the running application"
	@echo "  make test-dataset     Validate dataset files"
	@echo "  make test-record      Verify ingested record is accessible"
	@echo "  make test-all         Run all tests in sequence"
	@echo ""
	@echo "  make logs             Tail all application logs"
	@echo "  make restart          Restart all supervisor processes"
	@echo "  make stop             Shut down supervisor"
	@echo ""

deploy:
	bash deploy.sh

# ── Tests ─────────────────────────────────────────────────────────────────────

test-services:
	bash tests/01_services.sh

test-app:
	bash tests/02_app.sh

test-dataset:
	bash tests/03_ingest.sh

test-record:
	bash tests/04_api_record.sh

test-all: test-services test-app test-dataset test-record
	@echo ""
	@echo "All test suites passed."

# ── Application management ────────────────────────────────────────────────────

logs:
	tail -f /tmp/invenio-ui.log /tmp/invenio-api.log /tmp/celery.log

restart:
	supervisorctl -c $(SUPERVISOR_CONF) restart all

stop:
	supervisorctl -c $(SUPERVISOR_CONF) shutdown
